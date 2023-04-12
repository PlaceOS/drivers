require "json"

module TwentyFiveLivePro
  module Models
    struct Feature
      include JSON::Serializable

      @[JSON::Field(key: "featureId")]
      property feature_id : Int64
      @[JSON::Field(key: "quantity")]
      property quantity : Int64
    end
  end
end
