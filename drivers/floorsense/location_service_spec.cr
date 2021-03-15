DriverSpecs.mock_driver "Floorsense::LocationService" do
  system({
    Floorsense: {Floorsense},
  })

  resp = exec(:device_locations, "zone-level").get
  resp.should eq([
    {"location" => "desk", "at_location" => 1, "map_id" => "D403-01", "level" => "zone-level", "building" => "zone-building", "capacity" => 1, "mac" => "cid=3&key=D403-01", "floorsense_status" => 17, "floorsense_desk_type" => "a"},
  ])
end

class Floorsense < DriverSpecs::MockDriver
  def desks(plan_id : String)
    JSON.parse %([
    {
      "cid": 14,
      "status": 17,
      "cached": true,
      "eui64": "00124b0018ae56d0",
      "occupied": false,
      "freq": "915",
      "groupid": 0,
      "netid": 3,
      "key": "915-09",
      "reservable": true,
      "bkid": "",
      "deskid": 2,
      "hwfeat": 0,
      "created": 1568887923,
      "hardware": "E-20",
      "firmware": "401",
      "type": "a",
      "planid": 6,
      "reserved": false,
      "features": 0,
      "confirmed": false,
      "privacy": false,
      "uid": "",
      "occupiedtime": 0
    },
    {
      "cid": 3,
      "status": 17,
      "cached": true,
      "eui64": "00124b0018ae54e5",
      "occupied": true,
      "freq": "",
      "groupid": 0,
      "netid": 2,
      "key": "D403-01",
      "reservable": false,
      "bkid": "",
      "deskid": 129,
      "hwfeat": 0,
      "created": 1568887941,
      "hardware": "",
      "firmware": "",
      "type": "a",
      "planid": 6,
      "reserved": false,
      "features": 0,
      "confirmed": false,
      "privacy": false,
      "uid": "",
      "occupiedtime": 0
    }])
  end

  def bookings(plan_id : String)
    JSON.parse %({})
  end
end
