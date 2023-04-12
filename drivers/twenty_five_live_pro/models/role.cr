require "json"

module TwentyFiveLivePro
  module Models
    struct Role
      include JSON::Serializable

      @[JSON::Field(key: "roleId")]
      property role_id : Int64

      @[JSON::Field(key: "contactId")]
      property contact_id : Int64
    end
  end
end
