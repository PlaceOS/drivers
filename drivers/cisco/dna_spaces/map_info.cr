require "./events"

class Cisco::DNASpaces::Dimension
  include JSON::Serializable

  getter length : Float64
  getter width : Float64
  getter height : Float64

  @[JSON::Field(key: "offsetX")]
  getter offset_x : Float64

  @[JSON::Field(key: "offsetY")]
  getter offset_y : Float64
end

class Cisco::DNASpaces::MapInfo
  include JSON::Serializable

  @[JSON::Field(key: "mapId")]
  getter id : String

  @[JSON::Field(key: "imageWidth")]
  getter image_width : Float64

  @[JSON::Field(key: "imageHeight")]
  getter image_height : Float64

  getter dimension : Cisco::DNASpaces::Dimension
end
