require "placeos-driver/spec"
require "placeos-driver/interface/standby_image"

# :nodoc:
class DecoderMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::StandbyImage

  def set_background_image(url : String, output_index : Int32? = nil) : Nil
    self["background_image"] = url
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
    [
      {
        "id":       "item-1234",
        "media_id": "upload-1234",
      },
    ]
  end

  def signage_download_url(id : String)
    "https://background.image/url.jpg"
  end
end

DriverSpecs.mock_driver "Place::ImageUploader" do
  system({
    Decoder:          {DecoderMock, DecoderMock},
    StaffAPI:         {StaffAPIMock},
    LocationServices: {LocationServicesMock},
  })

  # local instances of the encoder mocks
  encoder1 = system(:Decoder_1).as(DecoderMock)
  encoder2 = system(:Decoder_1).as(DecoderMock)
  exec(:manual_update).get

  encoder1["background_image"]?.should eq "https://background.image/url.jpg"
  encoder2["background_image"]?.should eq "https://background.image/url.jpg"
end
