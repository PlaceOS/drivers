module Place; end

require "./area_polygon"

class Place::AreaCount < PlaceOS::Driver
  descriptive_name "PlaceOS Area Counter"
  generic_name :Counter
  description %(counts trackable objects in an area, such as people)

  default_settings({
    areas: [{
      id:       "lobby1",
      name:     "George St Lobby",
      building: "zone-12345",
      level:    "zone-34565",
      boundary: [{3, 5}, {5, 6}, {6, 1}],
    }],
  })

  alias AreaSetting = NamedTuple(
    id: String,
    name: String,
    building: String?,
    level: String?,
    boundary: Array(Tuple(Float64, Float64)))

  alias Area = NamedTuple(
    id: String,
    name: String,
    building: String?,
    level: String?,
    boundary: Polygon)

  @boundaries : Hash(String, Area) = {} of String => Area

  def on_load
    on_update
  end

  def on_update
    areas = setting(Array(AreaSetting), :areas)

    @boundaries.clear
    areas.each do |area|
      points = area[:boundary].map { |p| Point.new(*p) }
      @boundaries[area[:id]] = {
        id:       area[:id],
        name:     area[:name],
        building: area[:building],
        level:    area[:level],
        boundary: Polygon.new(points),
      }
    end
  end

  def is_inside?(x : Float64, y : Float64, area_id : String)
    area = @boundaries[area_id]
    area[:boundary].contains(x, y)
  end
end
