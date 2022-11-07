require "placeos-driver/spec"
require "./nvx_models"

DriverSpecs.mock_driver "Crestron::NvxAddressManager" do
  system({
    Encoder: {NvxEncoderMock, NvxEncoderMock},
  })

  exec(:readdress_streams).get.should eq 2

  system(:Encoder_1)[:address].should eq "239.8.0.2"
  system(:Encoder_2)[:address].should eq "239.8.0.10"
end

# :nodoc:
class NvxEncoderMock < DriverSpecs::MockDriver
  include Crestron::Transmitter

  def multicast_address(address : String)
    self[:address] = address
  end
end
