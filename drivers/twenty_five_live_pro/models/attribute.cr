require "json"

module TwentyFiveLivePro
  module Models
    struct Attribute
      include JSON::Serializable

      @[JSON::Field(key: "attributeId")]
      property attribute_id : Int64
    end
  end
end
