require "./events"

class Cisco::DNASpaces::Location
  include JSON::Serializable

  @[JSON::Field(key: "locationId")]
  getter location_id : String
  getter name : String

  # TODO:: this might be better as an enum
  # if there are only limited types
  @[JSON::Field(key: "inferredLocationTypes")]
  getter tags : Array(String) = [] of String

  getter parent : Location?

  # Maps tag names to location_ids
  def details(mappings = {} of String => String)
    parent.try &.details(mappings)
    tags.each { |tag| mappings[tag] = location_id }
    mappings
  end

  # Maps location_ids to location names
  def descriptions(mappings = {} of String => String)
    parent.try &.descriptions(mappings)
    mappings[location_id] = name
    mappings
  end
end
