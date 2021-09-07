require "placeos-driver/spec"

DriverSpecs.mock_driver "Vergesense::RoomSensor" do
  system({
    Vergesense: {VergesenseMock},
  })

  sleep 200.milliseconds

  status[:presence].should eq(true)
  status[:people].should eq(21)
  status[:capacity].should eq(3)

  sensors = exec(:sensors).get.not_nil!.as_a
  sensors.size.should eq 2

  sensor = exec(:sensor, sensors[0]["mac"], sensors[0]["id"]).get
  sensors[0].should eq sensor
end

# :nodoc:
class VergesenseMock < DriverSpecs::MockDriver
  def on_load
    self[:floor_key] = {
      "floor_ref_id" => "FL1",
      "name"         => "Floor 1",
      "capacity"     => 84,
      "max_capacity" => 60,
      "spaces"       => [
        {
          "building_ref_id" => "HQ1",
          "floor_ref_id"    => "FL1",
          "space_ref_id"    => "vergesense-room-id",
          "space_type"      => "conference_room",
          "name"            => "Conference Room 0721",
          "capacity"        => 4,
          "max_capacity"    => 3,
          "geometry"        => {"type" => "Polygon", "coordinates" => [[[93.850772, 44.676952], [93.850739, 44.676929], [93.850718, 44.67695], [93.850751, 44.676973], [93.850772, 44.676952], [93.850772, 44.676952]]]},
          "people"          => {
            "count"       => 21,
            "coordinates" => [[2.2673, 4.3891], [6.2573, 1.5303]],
          },
          "timestamp"       => "2019-08-21T21:10:25Z",
          "motion_detected" => true,
        },
      ],
    }
    self[:init_complete] = true
  end

  def floor_key(space_id : String)
    "floor_key"
  end
end
