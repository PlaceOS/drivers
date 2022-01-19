require "json"

# Meraki MQTT Data Models
module Cisco::Meraki
  class FloorMapping
    include JSON::Serializable

    getter camera_serials : Array(String)
    getter level_id : String
    getter building_id : String?
  end

  class DeskLocation
    include JSON::Serializable

    getter id : String
    getter x : Float32
    getter y : Float32
  end

  class DetectedDesks
    include JSON::Serializable

    @[JSON::Field(key: "_v")]
    getter api_version : String

    # Time in milliseconds v3,
    @[JSON::Field(key: "ts")]
    getter timestamp : Int64 | String

    getter desks : Array(Tuple(Float32, Float32,  # right
Float32, Float32,                                 # left
Float32, Float32,                                 # center
Float32                                           # occupancy
))
  end

  class LuxLevel
    include JSON::Serializable

    # Not actually provided for this message, but here for testing
    @[JSON::Field(key: "ts")]
    getter timestamp : Int64 { Time.utc.to_unix }

    getter lux : Float64
  end

  enum CountType
    People
    Vehicles
    Unknown
  end

  class Entrances
    include JSON::Serializable

    @[JSON::Field(key: "ts")]
    getter timestamp : Int64

    getter counts : NamedTuple(
      person: Int32?,
      vehicle: Int32?,
    )

    @[JSON::Field(ignore: true)]
    getter count_type : CountType do
      if counts[:person]
        CountType::People
      elsif counts[:vehicle]
        CountType::Vehicles
      else
        CountType::Unknown
      end
    end

    @[JSON::Field(ignore: true)]
    getter count : Int32 { counts[:person] || counts[:vehicle] || 0 }
  end
end