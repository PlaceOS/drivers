require "placeos-driver/spec"

DriverSpecs.mock_driver "Vergesense::LocationService" do
  system({
    Vergesense:     {VergesenseMock},
    AreaManagement: {AreaManagementMock},
  })

  resp = exec(:device_locations, "zone-level").get
  resp.should eq([
    {
      "location"              => "area",
      "at_location"           => 21,
      "map_id"                => "Conference Room 0721",
      "level"                 => "zone-level",
      "building"              => "zone-building",
      "capacity"              => 30,
      "vergesense_space_id"   => "CR_0721",
      "vergesense_space_type" => "conference_room",
      "area_humidity"         => nil,
      "area_temperature"      => nil,
      "area_air_quality"      => nil,
      "signs_of_life"         => nil,
    },
    {
      "location"              => "desk",
      "at_location"           => 1,
      "map_id"                => "desk-1234",
      "level"                 => "zone-level",
      "building"              => "zone-building",
      "capacity"              => 1,
      "vergesense_space_id"   => "CR_0722",
      "vergesense_space_type" => "desk",
      "area_humidity"         => nil,
      "area_temperature"      => nil,
      "area_air_quality"      => nil,
      "signs_of_life"         => nil,
    },
  ])
end

# :nodoc:
class VergesenseMock < DriverSpecs::MockDriver
  def on_load
    self["vergesense_building_id-floor_id"] = {
      "floor_ref_id" => "floor_id",
      "name"         => "Floor 1",
      "capacity"     => 84,
      "max_capacity" => 60,
      "spaces"       => [
        {
          "building_ref_id" => "vergesense_building_id",
          "floor_ref_id"    => "floor_id",
          "space_ref_id"    => "CR_0721",
          "space_type"      => "conference_room",
          "name"            => "Conference Room 0721",
          "capacity"        => 30,
          "max_capacity"    => 32,
          "geometry"        => {"type" => "Polygon", "coordinates" => [[[93.850772, 44.676952], [93.850739, 44.676929], [93.850718, 44.67695], [93.850751, 44.676973], [93.850772, 44.676952], [93.850772, 44.676952]]]},
          "people"          => {
            "count"       => 21,
            "coordinates" => [[[2.2673, 4.3891], [6.2573, 1.5303]]],
          },
          "timestamp"       => "2019-08-21T21:10:25Z",
          "motion_detected" => true,
        },
        {
          "building_ref_id" => "vergesense_building_id",
          "floor_ref_id"    => "floor_id",
          "space_ref_id"    => "CR_0722",
          "space_type"      => "desk",
          "name"            => "desk-1234",
          "capacity"        => 1,
          "max_capacity"    => 1,
          "geometry"        => {"type" => "Polygon", "coordinates" => [[[93.850772, 44.676952], [93.850739, 44.676929], [93.850718, 44.67695], [93.850751, 44.676973], [93.850772, 44.676952], [93.850772, 44.676952]]]},
          "people"          => {
            "count"       => 1,
            "coordinates" => [[[2.2673, 4.3891], [6.2573, 1.5303]]],
          },
          "timestamp"       => "2019-08-21T21:10:25Z",
          "motion_detected" => true,
        },
      ],
    }
  end
end

# :nodoc:
class AreaManagementMock < DriverSpecs::MockDriver
  def update_available(zones : Array(String))
    logger.info { "requested update to #{zones}" }
    nil
  end
end
