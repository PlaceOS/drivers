DriverSpecs.mock_driver "GlobalCache::Gc100" do
  # connected
  # get_devices
  should_send("getdevices\r")
  responds("device,2,3 RELAY\r")
  responds("endlistdevices\r")
  should_send("get_NET,0:1\r")

  exec(:relay, 1, true)
end
