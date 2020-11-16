require "./events"

class Cisco::DNASpaces::Location
  include JSON::Serializable

  @[JSON::Field(key: "locationId")]
  getter location_id : String
  getter name : String

  # TODO:: this might be better as an enum
  # if there are only limited types
  @[JSON::Field(key: "inferredLocationTypes")]
  getter tags : Array(String)

  getter parent : Location?

  def details(mappings = {} of String => String)
    parent.try &.details(mappings)
    tags.each { |tag| mappings[tag] = location_id }
    mappings
  end
end
