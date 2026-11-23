require "placeos-driver/spec"
require "placeos-driver/interface/standby_image"

# :nodoc:
class StandbyImageMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::StandbyImage

  def set_background_image(url : String, output_index : Int32? = nil) : Nil
    self[:uploads] = (self[:uploads]?.try(&.as_i) || 0) + 1
    failures = self[:failures]?.try(&.as_i) || 0
    if failures > 0
      self[:failures] = failures - 1
      raise "decoder failed to apply image"
    end
    self["background_image"] = url
    self[:ready] = true
  end
end

# :nodoc:
class DecoderMock < StandbyImageMock
  def background_image_ready?(output_index : Int32? = nil) : Bool
    self[:ready]?.try(&.as_bool) || false
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def get_systems_list
    {
      "zone-HWr2VJb49V": [
        # use the system ID that corresponds with this spec
        DriverSpecs::SYSTEM_ID,
      ],
    }
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def signage_playlist(system_id : String, last_downloaded : Int64? = nil)
    return nil if last_downloaded
    [
      {
        "id"         => "item-1234",
        "media_id"   => "upload-1234",
        "media_type" => "image",
        "updated_at" => self[:updated_at]?.try(&.as_i64) || 1_i64,
      },
    ]
  end

  def upload_content_url(id : String)
    "https://background.image.s3/bucket/folder/other.jpg"
  end

  def signage_download_url(id : String, ext : String = "png")
    "https://background.image/url.#{ext}"
  end

  def system_settings(id : String, key : String)
    self[:local_decoders]?.try(&.as_a).try &.map(&.as_s) if key == "local_decoders"
  end
end

DriverSpecs.mock_driver "Place::ImageUploader" do
  system({
    Decoder:          {DecoderMock},
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
  })

  settings({apply_exactly: true})
  decoder = system(:Decoder_1).as(DecoderMock)
  staff = system(:StaffAPI_1).as(StaffAPIMock)

  it "skips excluded and healthy receivers, and repairs failed or missing images" do
    staff[:local_decoders] = ["Decoder_2"]
    exec(:manual_update).get
    decoder[:uploads]?.should be_nil

    staff[:local_decoders] = ["Decoder_1"]
    exec(:manual_update).get
    decoder[:background_image]?.should eq "https://background.image/url.jpg"
    decoder[:uploads]?.should eq 1

    exec(:manual_update).get
    decoder[:uploads]?.should eq 1

    decoder[:ready] = false
    exec(:manual_update).get
    decoder[:uploads]?.should eq 2

    # A failed update must be retried on the next sweep, even when the old
    # image remains ready and the playlist hasn't changed again.
    staff[:updated_at] = 2
    decoder[:failures] = 1
    exec(:manual_update).get
    decoder[:uploads]?.should eq 3

    exec(:manual_update).get
    decoder[:uploads]?.should eq 4

    exec(:manual_update).get
    decoder[:uploads]?.should eq 4
  end

  it "syncs a display that implements only StandbyImage" do
    system({
      Display:          {StandbyImageMock},
      StaffAPI:         {StaffAPIMock},
      LocationServices: {LocationServicesMock},
    })
    status["background_images/#{DriverSpecs::SYSTEM_ID}"] = nil
    display = system(:Display_1).as(StandbyImageMock)
    staff = system(:StaffAPI_1).as(StaffAPIMock)
    staff[:local_decoders] = ["Display_1"]
    staff[:updated_at] = 1

    # A 304 provides no device read-back or delivery history for this display.
    display[:failures] = 1
    exec(:manual_update, Time.utc.to_unix).get
    display[:background_image]?.should be_nil
    display[:uploads]?.should eq 1

    exec(:manual_update).get
    display[:background_image]?.should eq "https://background.image/url.jpg"
    display[:uploads]?.should eq 2

    exec(:manual_update).get
    display[:uploads]?.should eq 2

    staff[:updated_at] = 2
    exec(:manual_update).get
    display[:uploads]?.should eq 3
  end
end
