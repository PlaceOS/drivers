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

  class NetworkDevice
    include JSON::Serializable

    @[JSON::Field(key: "id")]
    property id : String

    @[JSON::Field(key: "itemReference")]
    property item_reference : String

    @[JSON::Field(key: "name")]
    property name : String

    @[JSON::Field(key: "typeUrl")]
    property type_url : String

    @[JSON::Field(key: "self")]
    property self : String

    @[JSON::Field(key: "parentUrl")]
    property parent_url : String

    @[JSON::Field(key: "objectsUrl")]
    property objects_url : String

    @[JSON::Field(key: "networkDeviceUrl")]
    property network_device_url : String

    @[JSON::Field(key: "pointsUrl")]
    property points_url : String

    @[JSON::Field(key: "trendedAttributesUrl")]
    property trended_attributes_url : String

    @[JSON::Field(key: "alarmsUrl")]
    property alarms_url : String

    @[JSON::Field(key: "auditsUrl")]
    property audits_url : String
  end

  class Equipment
    include JSON::Serializable

    @[JSON::Field(key: "id")]
    property id : String

    @[JSON::Field(key: "itemReference")]
    property item_reference : String

    @[JSON::Field(key: "name")]
    property name : String

    @[JSON::Field(key: "type")]
    property type : String

    @[JSON::Field(key: "self")]
    property self : String

    @[JSON::Field(key: "spacesUrl")]
    property spaces_url : String

    @[JSON::Field(key: "networkDeviceUrl")]
    property network_device_url : String

    @[JSON::Field(key: "equipmentUrl")]
    property equipment_url : String

    @[JSON::Field(key: "upstreamEquipmentUrl")]
    property upstream_equipment_url : String

    @[JSON::Field(key: "pointsUrl")]
    property points_url : String
  end

  class Attribute
    include JSON::Serializable

    @[JSON::Field(key: "smaplesUrl")]
    property smaples_url : String

    @[JSON::Field(key: "attributeUrl")]
    property attribute_url : String
  end

  class Sample
    include JSON::Serializable

    @[JSON::Field(key: "timestamp")]
    property timestamp : String

    @[JSON::Field(key: "isReliable")]
    property reliable : Bool

    @[JSON::Field(key: "value")]
    property value : Hash(String, JSON::Any)
  end

  class GetSamplesForAnObjectAttributeResponse
    include JSON::Serializable

    @[JSON::Field(key: "total")]
    property total : Int32

    @[JSON::Field(key: "items")]
    property items : Array(Sample)

    @[JSON::Field(key: "next")]
    property next : String?

    @[JSON::Field(key: "previous")]
    property previous : String?

    @[JSON::Field(key: "self")]
    property self : String

    @[JSON::Field(key: "attributeUrl")]
    property attribute_url : String

    @[JSON::Field(key: "objectUrl")]
    property object_url : String
  end

  class GetNetworkDeviceChildrenResponse
    include JSON::Serializable

    @[JSON::Field(key: "total")]
    property total : Int32

    @[JSON::Field(key: "items")]
    property items : Array(NetworkDevice)

    @[JSON::Field(key: "next")]
    property next : String?

    @[JSON::Field(key: "previous")]
    property previous : String?

    @[JSON::Field(key: "self")]
    property self : String
  end

  class GetObjectAttributesWithSamplesResponse
    include JSON::Serializable

    @[JSON::Field(key: "total")]
    property total : Int32

    @[JSON::Field(key: "items")]
    property items : Array(Attribute)

    @[JSON::Field(key: "self")]
    property self : String
  end

  class GetEquipmentHostedByNetworkDeviceResponse
    include JSON::Serializable

    @[JSON::Field(key: "total")]
    property total : Int32

    @[JSON::Field(key: "items")]
    property items : Array(Equipment)

    @[JSON::Field(key: "next")]
    property next : String?

    @[JSON::Field(key: "previous")]
    property previous : String?

    @[JSON::Field(key: "self")]
    property self : String
  end

  class Command
    include JSON::Serializable

    @[JSON::Field(key: "commandId")]
    property command_id : String

    @[JSON::Field(key: "title")]
    property title : String

    @[JSON::Field(key: "type")]
    property type : String = "array"

    @[JSON::Field(key: "items")]
    property items : Array(JSON::Any)

    @[JSON::Field(key: "minItems")]
    property minimum_items : Int32

    @[JSON::Field(key: "maxItems")]
    property maximum_items : Int32
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

  class GetSingleObjectPresentValueResponse
    include JSON::Serializable

    class Item
      include JSON::Serializable

      class Value
        include JSON::Serializable

        @[JSON::Field(key: "value")]
        property value : String?

        @[JSON::Field(key: "reliability")]
        property reliability : String?

        @[JSON::Field(key: "priority")]
        property next : String?
      end
      @[JSON::Field(key: "presentValue")]
      property presentValue : Value
    end
    @[JSON::Field(key: "item")]
    property item : Item
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
