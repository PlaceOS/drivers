require "placeos-driver/spec"

# :nodoc:
class MistWebsocketMock < DriverSpecs::MockDriver
  def ownership_of(mac_address : String)
    raise "expected 1234a6789b got #{mac_address}" unless mac_address == "1234a6789b"
    "steve"
  end
end

DriverSpecs.mock_driver "Juniper::MistLocationService" do
  system({
    MistWebsocket: {MistWebsocketMock},
  })

  sleep 0.5

  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)

  # Should return ownership of a MAC Address
  exec(:check_ownership_of, "0x12:34:A6-789B").get.should eq({
    "location"    => "wireless",
    "assigned_to" => "steve",
    "mac_address" => "1234a6789b",
  })
end
