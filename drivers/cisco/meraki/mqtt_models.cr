require "json"

# Meraki MQTT Data Models
module Cisco::Meraki
  class FloorMapping
    include JSON::Serializable

    getter camera_serials : Array(String)
    getter level_id : String
    getter building_id : String?
  end

  class DetectedDesks
    include JSON::Serializable

    @[JSON::Field(key: "_v")]
    getter api_version : Int32

    # Time in milliseconds v3,
    @[JSON::Field(key: "ts")]
    getter time_unix : Int64?

    @[JSON::Field(key: "time")]
    getter time_string : String?

    getter desks : Array(Tuple(Float64, Float64,  # left
Float64, Float64,                                 # center
Float64, Float64,                                 # right
Float64                                           # occupancy
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
