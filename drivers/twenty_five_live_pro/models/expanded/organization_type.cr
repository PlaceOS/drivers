require "json"

module TwentyFiveLivePro
  module Models
    module Expanded
      struct OrganizationType
        include JSON::Serializable

        @[JSON::Field(key: "organizationTypeId")]
        property organization_type_id : Int64
        @[JSON::Field(key: "organizationTypeName")]
        property organization_type_name : String
      end
    end
  end
end
