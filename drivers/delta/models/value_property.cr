require "./**"
require "json"

module Delta
  module Models
    struct ValueProperty
      include JSON::Serializable

      @[JSON::Field(key: "$base")]
      property base : String

      @[JSON::Field(key: "displayName")]
      property display_name : String

      @[JSON::Field(key: "object-identifier")]
      property object_identifier : GenericValue

      @[JSON::Field(key: "object-type")]
      property object_type : GenericValue

      @[JSON::Field(key: "object-name")]
      property object_name : GenericValue

      @[JSON::Field(key: "exchange-flags")]
      property exchange_flags : GenericValue

      @[JSON::Field(key: "exchange-type")]
      property exchange_type : GenericValue

      @[JSON::Field(key: "last-error")]
      property last_error : GenericValue

      @[JSON::Field(key: "local-ref")]
      property local_ref : Reference

      @[JSON::Field(key: "local-flags")]
      property local_flags : GenericValue

      @[JSON::Field(key: "local-value")]
      property local_flags : LocalValue

      @[JSON::Field(key: "subscribers")]
      property subscribers : Hash(String, JSON::Any)

      @[JSON::Field(key: "last-sent")]
      property last_sent : GenericValue

      @[JSON::Field(key: "send-frequency")]
      property send_frequency : GenericValue

      @[JSON::Field(key: "cov-increment")]
      property cov_increment : GenericValue
    end
  end
end
