require "json"

module Delta
  module Models
    struct Reference
      include JSON::Serializable

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "type")]
      property type : String

      @[JSON::Field(key: "deviceIdentifier")]
      property device_identifier : GenericValue

      @[JSON::Field(key: "objectIdentifier")]
      property object_identifier : GenericValue

      @[JSON::Field(key: "propertyIdentifier")]
      property property_identifier : PropertyIdentifier
    end
  end
end
