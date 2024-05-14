require "json"

module Optergy
  enum Units
    Metric
    Imperial
  end

  struct Config
    include JSON::Serializable

    getter units : Units
    getter id : Int64
  end

  struct AnalogValue
    include JSON::Serializable

    @[JSON::Field(key: "objectName")]
    getter name : String { "" }
    getter description : String { "" }

    @[JSON::Field(key: "presentValue")]
    getter value_str : String
    getter instance : Int32

    @[JSON::Field(key: "outOfService")]
    getter? out_of_service : Bool

    getter units : Int32?

    getter value : Float64 do
      value_str.to_f? || 0.0
    end
  end

  struct BinaryValue
    include JSON::Serializable

    @[JSON::Field(key: "objectName")]
    getter name : String { "" }
    getter description : String { "" }

    @[JSON::Field(key: "presentValue")]
    getter value_str : String
    getter instance : Int32

    @[JSON::Field(key: "outOfService")]
    getter? out_of_service : Bool

    getter units : Int32?

    getter value : Bool do
      value_str == "Active"
    end
  end

  ANALOG_INPUT_MODE = {
    "2"       => "10k-2 sensor",
    "6"       => "Dry Contact",
    "4|10"    => "Pulse 10 per pulse",
    "3|0|100" => "4-20 ma 0 to 100",
    "5"       => "3K sensor",
  }

  struct ModeResponse
    include JSON::Serializable

    getter mode : String
    getter instance : Int32

    @[JSON::Field(key: "objectType")]
    getter object_type : Int32
  end
end
