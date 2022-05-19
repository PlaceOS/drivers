require "placeos-driver/spec"

DriverSpecs.mock_driver "Vergesense::RoomSensor" do
  system({
    KontaktIO: {KontaktIOMock},
  })

  sleep 200.milliseconds

  status[:presence].should eq(true)
  status[:people].should eq(3)

  sensors = exec(:sensors).get.not_nil!.as_a
  sensors.size.should eq 2

  sensor = exec(:sensor, sensors[0]["mac"], sensors[0]["id"]).get
  sensors[0].should eq sensor
end

# :nodoc:
class KontaktIOMock < DriverSpecs::MockDriver
  def on_load
    self["room-kontakt-room-id"] = {
      "roomId"       => 195835,
      "roomName"     => "Open Pod",
      "floorId"      => 195528,
      "floorName"    => "Lower ground floor",
      "buildingId"   => 193637,
      "buildingName" => "Showroom",
      "campusId"     => 193296,
      "campusName"   => "Showroom",
      "lastUpdate"   => "2022-04-21T21:55:56.751Z",
      "occupancy"    => 3,
    }
  end
end
