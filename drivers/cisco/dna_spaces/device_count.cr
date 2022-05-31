require "./events"

class Cisco::DNASpaces::DeviceCount
  include JSON::Serializable

  getter location : Location

  @[JSON::Field(key: "associatedCount")]
  getter associated_count : Int32

  @[JSON::Field(key: "estimatedProbingCount")]
  getter estimated_probing_count : Int32

  @[JSON::Field(key: "probingRandomizedPercentage")]
  getter probing_randomized_percentage : Float64

  @[JSON::Field(key: "estimatedDensity")]
  getter estimated_density : Float64

  @[JSON::Field(key: "estimatedCapacityPercentage")]
  getter estimated_capacity_percentage : Float64
end
