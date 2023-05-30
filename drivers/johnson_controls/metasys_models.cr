require "json"

module JohnsonControls
  ISO8601 = Time::Format.new("%FT%TZ")

  class AuthResponse
    include JSON::Serializable

    @[JSON::Field(key: "accessToken")]
    property access_token : String

    @[JSON::Field(converter: JohnsonControls::ISO8601)]
    property expires : Time
  end

  class EquipmentPoints
    include JSON::Serializable

    @[JSON::Field(key: "items")]
    property points : Array(Point)
  end

  class Point
    include JSON::Serializable

    @[JSON::Field(key: "label")]
    property name : String

    @[JSON::Field(key: "equipmentName")]
    property equipment_name : String

    @[JSON::Field(key: "objectUrl")]
    property object_url : String
  end

  class SamplesResponse
    include JSON::Serializable

    property items : Array(Item)
  end

  class Item
    include JSON::Serializable

    property value : Value
  end

  class Value
    include JSON::Serializable

    @[JSON::Field(key: "value")]
    property actual : Float64
  end
end
