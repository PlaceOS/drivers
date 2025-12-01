require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Bookings::RoomSensor" do
  settings({
    area_id: "map_id",
  })

  system({
    AreaManagement: {AreaManagementMock},
  })

  sleep 200.milliseconds

  exec(:update_sensor).get

  status[:presence].should eq(1)
  status[:people].should eq(4)

  sensors = exec(:sensors).get.not_nil!.as_a
  sensors.size.should eq 2

  sensor = exec(:sensor, sensors[0]["mac"], sensors[0]["id"]).get
  sensors[0].should eq sensor
end

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def on_load
    self["zone-level:areas"] = JSON.parse(%({
        "value": [
            {
                "area_id": "map_id",
                "name": "map_id",
                "count": 2.5,
                "temperature": 25.8,
                "humidity": 49,
                "counter": 4,
                "capacity": 10
            }
        ],
        "measurement": "area_summary",
        "ts_hint": "complex",
        "ts_tags": {
            "pos_building": "zone-building",
            "pos_level": "zone-level"
        }
    }))
  end

  def level_buildings
    {
      "zone-level" => "zone-building",
    }
  end
end
