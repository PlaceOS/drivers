require "placeos-driver/spec"

DriverSpecs.mock_driver "KontaktIO::SensorService" do
  system({
    KontaktIO: {KontaktIOMock},
  })
  settings({
    floor_mappings: {
      "195528" => {
        building_id: "zone-building",
        level_id:    "zone-level",
        name:        "friendly name for documentation",
      },
    },
  })

  # build the cache
  exec(:cache_occupancy_counts).get

  # lookup a sensor value
  resp = exec(:sensor, "kontakt-195835", "people").get.not_nil!
  resp["mac"].should eq "kontakt-195835"
  resp["id"].should eq "people"
  resp["value"].should eq 3.0
  resp["level"].should eq "zone-level"
  resp["building"].should eq "zone-building"
end

# :nodoc:
class KontaktIOMock < DriverSpecs::MockDriver
  def room_occupancy
    [
      {
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
      },
    ]
  end
end
