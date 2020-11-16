require "./events"

class Cisco::DNASpaces::MapInfo
  include JSON::Serializable

  @[JSON::Field(key: "mapId")]
  getter id : String

  @[JSON::Field(key: "imageWidth")]
  getter image_width : Float64

  @[JSON::Field(key: "imageHeight")]
  getter image_height : Float64
end
