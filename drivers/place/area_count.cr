module Place; end

require "pinger"

class Place::AreaCount < PlaceOS::Driver
  descriptive_name "PlaceOS Area Counter"
  generic_name :Counter
  description %(counts trackable objects in an area, such as people)

  default_settings({
    areas: [{
      name: "lobby",
      building: "zone-12345",
      level: "zone-34565",
      boundary: [{3, 5}, {8, 9}, {4, 6}]
    }],
  })

  alias Area = NamedTuple(
    name: String,
    building: String?,
    level: String?,
    boundary: Array(Tuple(Int64, Int64))
  )

  @boundaries : Array(Area) = [] of Area

  def on_load
    on_update
  end

  def on_update
    @boundaries = setting(Array(Area), :areas)
  end
end
