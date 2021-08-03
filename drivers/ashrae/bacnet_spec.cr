require "placeos-driver/spec"

# NOTE:: this spec only works if there is a BACnet network configured locally
# such as https://github.com/chipkin/BACnetServerExampleCPP/releases
DriverSpecs.mock_driver "Ashrae::BACnet" do
  exec(:query_known_devices).get
  (exec(:devices).get.not_nil!.size > 0).should be_true
end
