require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::OccupancySensor" do
  # Connected callback makes some queries
  should_send "/Device/OccupancySensor/IsRoomOccupied"
  responds %({"Device": {"OccupancySensor": {"IsRoomOccupied": true}}})

  should_send "/Device/DeviceInfo/MacAddress"
  responds %({"Device": {"DeviceInfo": {"MacAddress": "00.10.7f.ec.2d.72"}}})

  should_send "/Device/DeviceInfo/Name"
  responds %({"Device": {"DeviceInfo": {"Name": "Room1 Sensor"}}})

  sleep 1
  status[:occupied].should eq true
  status[:name].should eq "Room1 Sensor"
  status[:mac].should eq "00107fec2d72"

  transmit %({"Device": {"OccupancySensor": {"IsRoomOccupied": false}}})
  sleep 1
  status[:occupied].should eq false

  resp = exec(:get_sensor_details).get.not_nil!
  resp.should eq({
    "status"    => "normal",
    "type"      => "presence",
    "value"     => 0.0,
    "last_seen" => resp["last_seen"].as_i64,
    "mac"       => "00107fec2d72",
    "name"      => "Room1 Sensor",
    "module_id" => "spec_runner",
    "binding"   => "occupied",
    "location"  => "sensor",
  })
end
