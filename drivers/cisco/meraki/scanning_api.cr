module Cisco; end

require "json"

module Cisco::Meraki
  ISO8601 = "%FT%T%z"

  class Client
    include JSON::Serializable

    property id : String
    property mac : String
    property description : String?

    property ip : String?
    property ip6 : String?

    @[JSON::Field(key: "ip6Local")]
    property ip6_local : String?

    property user : String?

    # 2020-09-29T07:53:08Z
    @[JSON::Field(key: "firstSeen")]
    property first_seen : String

    @[JSON::Field(key: "lastSeen")]
    property last_seen : String

    property manufacturer : String?
    property os : String?

    @[JSON::Field(key: "recentDeviceMac")]
    property recent_device_mac : String?
    property ssid : String?
    property vlan : Int32?
    property switchport : String?
    property status : String
    property notes : String?

    @[JSON::Field(ignore: true)]
    property! time_added : Time
  end

  class RSSI
    include JSON::Serializable

    @[JSON::Field(key: "apMac")]
    property access_point_mac : String
    property rssi : Int32
  end

  class Location
    include JSON::Serializable

    # NOTE:: This is not part of the location response,
    # it is here to simplify processing
    @[JSON::Field(ignore: true)]
    property mac : String?

    # NOTE:: this is not part of the location response,
    # it is here to speed up processing
    @[JSON::Field(ignore: true)]
    property client : Client? = nil

    # Multiple types as the location when parsed might include javascript `"NaN"`
    property x : Float64 | String | Nil
    property y : Float64 | String | Nil
    property lng : Float64?
    property lat : Float64?
    property variance : Float64

    @[JSON::Field(key: "floorPlanId")]
    property floor_plan_id : String?

    @[JSON::Field(key: "floorPlanName")]
    property floor_plan_name : String?

    @[JSON::Field(converter: Time::Format.new(Cisco::Meraki::ISO8601))]
    property time : Time

    @[JSON::Field(key: "nearestApTags")]
    property nearest_ap_tags : Array(String)

    @[JSON::Field(key: "rssiRecords")]
    property rssi_records : Array(RSSI)

    def x!
      get_x.not_nil!
    end

    def y!
      get_y.not_nil!
    end

    def get_x : Float64?
      if tmp = x
        if tmp.is_a?(Float64)
          tmp
        end
      end
    end

    def get_y : Float64?
      if tmp = y
        if tmp.is_a?(Float64)
          tmp
        end
      end
    end
  end

  class LatestRecord
    include JSON::Serializable

    @[JSON::Field(key: "nearestApMac")]
    property nearest_ap_mac : String

    @[JSON::Field(key: "nearestApRssi")]
    property nearest_ap_rssi : Int32

    @[JSON::Field(converter: Time::Format.new(Cisco::Meraki::ISO8601))]
    property time : Time
  end

  class Observation
    include JSON::Serializable

    @[JSON::Field(key: "clientMac")]
    property client_mac : String

    property manufacturer : String?
    property ipv4 : String?
    property ipv6 : String?
    property ssid : String?
    property os : String?

    @[JSON::Field(key: "latestRecord")]
    property latest_record : LatestRecord
    property locations : Array(Location)
  end

  class Data
    include JSON::Serializable

    @[JSON::Field(key: "networkId")]
    property network_id : String
    property observations : Array(Observation)
  end

  class DevicesSeen
    include JSON::Serializable

    property version : String
    property secret : String

    @[JSON::Field(key: "type")]
    property message_type : String

    property data : Data
  end
end
