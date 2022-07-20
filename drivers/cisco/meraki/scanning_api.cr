require "json"
require "./geo"

module Cisco::Meraki
  ISO8601 = "%FT%T%z"

  class Organization
    include JSON::Serializable

    property id : String
    property name : String
    property url : String
    property api : NamedTuple(enabled: Bool)
  end

  class Network
    include JSON::Serializable

    property id : String

    @[JSON::Field(key: "organizationId")]
    property organization_id : String

    property name : String

    @[JSON::Field(key: "productTypes")]
    property product_types : Array(String)

    @[JSON::Field(key: "timeZone")]
    property time_zone : String
    property tags : Array(String)
    property url : String

    @[JSON::Field(key: "enrollmentString")]
    property enrollment_string : String?
    property notes : String?
  end

  class CameraAnalytics
    include JSON::Serializable
    ISO8601_MS = "%FT%T.%3N%z"

    class PeopleCount
      include JSON::Serializable

      property person : Int32
    end

    @[JSON::Field(converter: Time::Format.new(Cisco::Meraki::CameraAnalytics::ISO8601_MS))]
    property ts : Time
    property zones : Hash(Int64, PeopleCount)
  end

  class FloorPlan
    include JSON::Serializable

    @[JSON::Field(key: "floorPlanId")]
    property id : String
    property width : Float64
    property height : Float64

    @[JSON::Field(key: "topLeftCorner")]
    property top_left : Geo::Point

    @[JSON::Field(key: "bottomLeftCorner")]
    property bottom_left : Geo::Point

    @[JSON::Field(key: "bottomRightCorner")]
    property bottom_right : Geo::Point

    # This is useful for when we have to map meraki IDs to our zones
    property name : String?

    def to_distance
      Geo::Distance.new(width, height)
    end
  end

  class FloorPlanLocation
    include JSON::Serializable

    property id : String
    property name : String
    property x : Float64
    property y : Float64
  end

  class NetworkDevice
    include JSON::Serializable

    # Used for caching the location calculated for this device
    # where an observation doesn't have location values but has a closest WAP
    @[JSON::Field(ignore: true)]
    property location : DeviceLocation?

    @[JSON::Field(key: "floorPlanId")]
    property floor_plan_id : String?

    property lat : Float64
    property lng : Float64
    property mac : String

    property serial : String
    property model : String
    property firmware : String

    # This is useful for when we have to map meraki IDs to our zones
    property name : String?
  end

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
    property vlan : String?
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

  class DeviceLocation
    include JSON::Serializable

    def initialize(@x, @y, @lng, @lat, @variance, floor_plan_id, floor_plan_name, @time)
      @wifi_floor_plan_name = floor_plan_name
      @wifi_floor_plan_id = floor_plan_id
      @mac = nil
      @client = nil
      @rssi_records = [] of RSSI
    end

    def self.calculate_location(floor : FloorPlan, device : NetworkDevice, time : Time) : DeviceLocation
      distance = Geo.calculate_xy(floor.top_left, floor.bottom_left, floor.bottom_right, device, floor.to_distance)
      DeviceLocation.new(distance.x, distance.y, device.lng, device.lat, 25_f64, floor.id, floor.name, time)
    end

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
    property wifi_floor_plan_id : String?

    @[JSON::Field(key: "floorPlanName")]
    property wifi_floor_plan_name : String?

    @[JSON::Field(key: "floorPlan")]
    property floor_plan : FloorPlanLocation?

    @[JSON::Field(converter: Time::Format.new(Cisco::Meraki::ISO8601))]
    property time : Time

    @[JSON::Field(key: "nearestApTags")]
    property nearest_ap_tags : Array(String) { [] of String }

    @[JSON::Field(key: "rssiRecords")]
    property rssi_records : Array(RSSI)

    def x!
      get_x.not_nil!
    end

    def y!
      get_y.not_nil!
    end

    def get_x : Float64?
      if tmp = x || floor_plan.try(&.x)
        if tmp.is_a?(Float64)
          tmp
        end
      end
    end

    def get_y : Float64?
      if tmp = y || floor_plan.try(&.y)
        if tmp.is_a?(Float64)
          tmp
        end
      end
    end

    def floor_plan_id
      wifi_floor_plan_id || floor_plan.try(&.id)
    end

    def floor_plan_name
      wifi_floor_plan_name || floor_plan.try(&.name)
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
    property locations : Array(DeviceLocation)
  end

  class Data
    include JSON::Serializable

    @[JSON::Field(key: "networkId")]
    property network_id : String
    property observations : Array(Observation)
  end

  enum MessageType
    None
    WiFi
    Bluetooth
  end

  class DevicesSeen
    include JSON::Serializable

    property version : String
    property secret : String

    @[JSON::Field(key: "type")]
    property message_type : MessageType

    property data : Data
  end

  struct CameraZone
    include JSON::Serializable

    struct Region
      include JSON::Serializable

      getter x0 : String
      getter y0 : String
      getter x1 : String
      getter y1 : String
    end

    getter id : String
    getter type : String
    getter label : String

    @[JSON::Field(key: "regionOfInterest")]
    getter region : Region

    @[JSON::Field(ignore: true)]
    property distance : Float64 = 0.0

    def mid_point
      mid_x = (region.x0.to_f64 + region.x1.to_f64) / 2.0
      mid_y = (region.y0.to_f64 + region.y1.to_f64) / 2.0
      {mid_x, mid_y}
    end

    getter x : Float64 do
      xpos, @y = mid_point
      xpos
    end

    getter y : Float64 do
      @x, ypos = mid_point
      ypos
    end
  end
end
