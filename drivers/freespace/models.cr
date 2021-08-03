require "json"

module Freespace
  class SpaceActivity
    include JSON::Serializable

    property id : Int64

    @[JSON::Field(key: "spaceId")]
    property space_id : Int64

    @[JSON::Field(key: "utcEpoch")]
    property utc_epoch : Int64
    property state : Int32

    def presence?
      @state > 0
    end

    @[JSON::Field(ignore: true)]
    property! location_id : Int64

    @[JSON::Field(ignore: true)]
    property! capacity : Int32

    @[JSON::Field(ignore: true)]
    property! name : String
  end

  # ====
  # Classes related to a space
  # ====

  class Location
    include JSON::Serializable

    property id : Int64

    # undocumented, can be nil
    # @[JSON::Field(key: "scalingFactor")]
    # property scaling_factor : Float64?

    property raw : Bool
    property policy : Bool
  end

  class SRF
    include JSON::Serializable

    property x : Int32
    property y : Int32
    property z : Int32
  end

  class Category
    include JSON::Serializable

    property id : Int64
    property name : String

    @[JSON::Field(key: "shortName")]
    property short_name : String?

    @[JSON::Field(key: "showOnSignage")]
    property show_on_signage : Bool

    @[JSON::Field(key: "showInAnalytics")]
    property show_in_analytics : Bool

    @[JSON::Field(key: "iconUrl")]
    property icon_url : String?

    # RGB value i.e. #ffb3b3
    @[JSON::Field(key: "colorScheme")]
    property color_scheme : String?

    @[JSON::Field(key: "orderingIndex")]
    property ordering_index : Int32?
  end

  class Device
    include JSON::Serializable

    property id : Int64

    @[JSON::Field(key: "displayName")]
    property name : String

    # Many more undocumented fields
  end

  class Space
    include JSON::Serializable

    property id : Int64
    property location : Location
    property name : String
    property srf : SRF

    # undocumented, possibly polymorphic: {"type" => "CIRCLE", "data" => "20"},
    property marker : Hash(String, JSON::Any)

    @[JSON::Field(key: "subCategory")]
    property sub_category : Category
    property category : Category
    property department : Category

    @[JSON::Field(key: "sensingPolicyId")]
    property sensing_policy_id : Int32
    property device : Device

    @[JSON::Field(key: "markerUniqueId")]
    property marker_unique_id : String?
    property live : Bool
    property capacity : Int32

    # unsure about this field
    # property counter : String

    property serial : Int32

    @[JSON::Field(key: "locationId")]
    property location_id : Int64
    property counted : Bool
  end
end
