DriverSpecs.mock_driver "GlobalCache::Gc100" do
  # connected
  # get_devices
  should_send("getdevices\r")
  responds("device,2,3 RELAY\r")
  responds("device,1,2 RELAYSENSOR\r")
  responds("device,3,1 IR\r")
  responds("endlistdevices\r")
  should_send("get_NET,0:1\r")
  status[:relay_config].should eq({
    "relay" => {"0" => "2:1", "1" => "2:2", "2" => "2:3"},
    "relaysensor" => {"0" => "1:1", "1" => "1:2", "2" => "1:3", "3" => "1:4"},
    "ir" => {"0" => "3:1"}
  })
  status[:port_config].should eq({
    "2:1" => ["relay", 0], "2:2" => ["relay", 1], "2:3" => ["relay", 2], "1:1" => ["relaysensor", 0], "1:2" => ["relaysensor", 1], "3:1" => ["ir", 0]
  })

  exec(:relay, 1, true)
  should_send("setstate,2:2,1\r")
  responds("state,2:2,1\r")
  status[:relay1].should eq(true)

  exec(:ir, 0, "4444")
  should_send("sendir,1:0,4444\r")
  responds("completeir,1:0,4444\r")

  exec(:set_ir, 0, "ir")
  should_send("set_IR,3:1,IR\r")
  responds("TODO 1\r")

  exec(:relay_status?, 2)
  should_send("getstate,2:3\r")
  responds("state,2:3,0\r")
  status[:relay2].should eq(false)

  exec(:ir_status?, 0)
  should_send("getstate,3:1\r")
  responds("state,3:1,1\r")
  status[:ir0].should eq(true)
end
