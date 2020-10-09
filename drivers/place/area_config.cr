require "json"
require "./area_polygon"

module Place
  class Geometry
    include JSON::Serializable

    def initialize(@coordinates, @geo_type = "Polygon")
    end

    @[JSON::Field(key: "type")]
    property geo_type : String
    property coordinates : Array(Tuple(Float64, Float64))
  end

  class AreaConfig
    include JSON::Serializable

    def initialize(@id, name, coordinates, building_id = nil, @area_type = "Feature", @feature_type = "section")
      @geometry = Geometry.new(coordinates)
      @properties = {
        "name" => name,
      }
      @properties["building_id"] = building_id if building_id
    end

    @polygon : Polygon? = nil

    property id : String

    @[JSON::Field(key: "type")]
    property area_type : String
    property feature_type : String

    property geometry : Geometry
    property properties : Hash(String, String)

    def name
      self.properties["name"]
    end

    def building
      self.properties["building_id"]?
    end

    def coordinates
      self.geometry.coordinates
    end

    def polygon : Polygon
      @Polygon ||= Polygon.new(coordinates.map { |coords| Point.new(*coords) })
    end
  end
end
