require "json"

module Vecos
  struct LockerBank
    include JSON::Serializable

    @[JSON::Field(key: "Id")]
    getter id : String

    @[JSON::Field(key: "Name")]
    getter name : String

    @[JSON::Field(key: "SectionId")]
    getter section_id : String

    @[JSON::Field(key: "LocationId")]
    getter location_id : String?

    @[JSON::Field(key: "Published")]
    getter published : Bool

    @[JSON::Field(key: "RandomAllocation")]
    getter random_allocation : Bool?

    @[JSON::Field(key: "ServiceMode")]
    getter service_mode : Bool

    @[JSON::Field(key: "Description")]
    getter description : String?
  end
end
