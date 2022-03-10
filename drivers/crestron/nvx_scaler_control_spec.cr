require "placeos-driver/spec"
require "./nvx_rx_models"

DriverSpecs.mock_driver "Crestron::NvxScalerControl" do
  system({
    Decoder:   {NvxDecoderMock, NvxDecoderMock},
    VideoWall: {VideoWallMock},
  })

  sleep 1

  system(:Decoder_1)[:aspect_ratio].should eq "MaintainAspectRatio"
  system(:Decoder_2)[:aspect_ratio].should eq "StretchToFit"
end

# :nodoc:
class NvxDecoderMock < DriverSpecs::MockDriver
  def aspect_ratio(mode : Crestron::AspectRatio)
    self[:aspect_ratio] = mode
  end
end

# :nodoc:
class VideoWallMock < DriverSpecs::MockDriver
  def on_load
    self[:windows] = {
      "window_1" => {
        canwidth:  1920,
        canheight: 1080,
      },
      "window_2" => {
        canwidth:  1080,
        canheight: 1080,
      },
    }
  end
end
