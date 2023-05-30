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

    def initialize(@id, name, coordinates, building_id = nil, @area_type = "Feature", @feature_type = "section", capacity = nil)
      @geometry = Geometry.new(coordinates)
      @properties = Hash(String, JSON::Any::Type | Hash(String, JSON::Any)).new
      @properties["name"] = name
      @properties["building_id"] = building_id if building_id
      @properties["capacity"] = capacity if capacity
    end

    @[JSON::Field(ignore: true)]
    @polygon : Polygon? = nil

    property id : String

    @[JSON::Field(key: "type")]
    property area_type : String
    property feature_type : String

    property geometry : Geometry
    property properties : Hash(String, JSON::Any::Type)

    @[JSON::Field(ignore: true)]
    @adjusted_coords : Array(Tuple(Float64, Float64))? = nil

    def name : String
      self.properties["name"].as(String)
    end

    def building : String?
      self.properties["building_id"]?.as?(String)
    end

    def capacity : Int32?
      self.properties["capacity"]?.as?(Int64 | Float64).try &.to_i
    end

    def coordinates
      if coords = @adjusted_coords
        coords
      else
        self.geometry.coordinates
      end
    end

    def coordinates(map_width : Float64, map_height : Float64)
      @adjusted_coords = self.geometry.coordinates.map { |(x, y)| {x * map_width, y * map_height} }
    end

    def polygon : Polygon
      @polygon ||= Polygon.new(coordinates.map { |coords| Point.new(*coords) })
    end
  end
end
