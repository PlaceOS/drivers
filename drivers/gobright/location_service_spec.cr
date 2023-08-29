require "placeos-driver/spec"
require "./models"

DriverSpecs.mock_driver "GoBright::LocationService" do
  system({
    GoBright:       {GoBrightMock},
    StaffAPI:       {StaffAPIMock},
    AreaManagement: {AreaManagementMock},
  })

  exec(:device_locations, "placeos_zone_id").get.should eq([
    {
      "location"             => "desk",
      "at_location"          => 0,
      "map_id"               => "desk-1",
      "level"                => "placeos_zone_id",
      "building"             => "zone-1234",
      "capacity"             => 1,
      "gobright_location_id" => "level",
      "gobright_space_name"  => "desk-1",
      "gobright_space_type"  => "desk",
      "gobright_space_id"    => "space-1234",
    }, {
      "location"             => "area",
      "at_location"          => 1,
      "map_id"               => "room-1",
      "level"                => "placeos_zone_id",
      "building"             => "zone-1234",
      "capacity"             => 1,
      "gobright_location_id" => "level",
      "gobright_space_name"  => "room-1",
      "gobright_space_type"  => "room",
      "gobright_space_id"    => "space-4567",
    },
  ])
end

# :nodoc:
class GoBrightMock < DriverSpecs::MockDriver
  def spaces(location : String? = nil, types : GoBright::SpaceType | Array(GoBright::SpaceType)? = nil)
    [
      {
        id:         "space-1234",
        locationId: "level",
        name:       "desk-1",
        type:       1,
      },
      {
        id:         "space-4567",
        locationId: "level",
        name:       "room-1",
        type:       0,
      },
    ]
  end

  def live_occupancy(location : String? = nil, type : GoBright::SpaceType? = nil)
    [
      {
        spaceId:            "space-1234",
        occupationDetected: false,
      },
      {
        spaceId:            "space-4567",
        occupationDetected: true,
      },
    ]
  end

  def bookings(starting : Int64, ending : Int64, location_id : String | Array(String)? = nil, space_id : String | Array(String)? = nil)
    [] of Nil
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def zones(tags : String)
    logger.info { "zones requested from staff api" }
    raise "unexpected tags, expected building, got: #{tags}" unless tags == "building"

    # NOTE:: zone-1234 is the default zone used in the spec runner
    [{id: "zone-1234"}]
  end
end

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def level_details
    {} of String => String
  end
end
