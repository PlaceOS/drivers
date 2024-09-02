require "json"

module Juniper
  class Site
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property timezone : String
    property country_code : String
    property id : String
    property name : String
    property org_id : String
    property created_time : Int64
    property modified_time : Int64
  end

  abstract class Map
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property name : String
    property id : String

    use_json_discriminator "type", {
      "image"  => MapImage,
      "google" => MapGoogle,
    }
  end

  class MapImage < Map
    getter type : String = "image"
    property url : String
    property thumbnail_url : String

    property site_id : String?
    property org_id : String?

    @[JSON::Field(key: "ppm")]
    property pixels_per_meter : Float32?
    property width : Int32
    property height : Int32

    property width_m : Float64?
    property height_m : Float64?

    # the user-annotated x origin, pixels
    property origin_x : Int32?

    # the user-annotated y origin, pixels
    property origin_y : Int32?
    property orientation : Int32?
    property locked : Bool?
  end

  class MapGoogle < Map
    getter type : String = "google"
    property view : String
    property origin_x : Float64
    property origin_y : Float64

    @[JSON::Field(key: "latlng_tl")]
    property top_left_coordinates : LatLng

    @[JSON::Field(key: "latlng_br")]
    property bottom_right_coordinates : LatLng
  end

  struct LatLng
    include JSON::Serializable

    property lat : Float64
    property lng : Float64
  end

  class Client
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property mac : String
    property last_seen : Int64

    property username : String?
    property hostname : String?
    property os : String?
    property manufacture : String?
    property family : String?
    property model : String?

    @[JSON::Field(key: "ip")]
    property ip_address : String
    property ap_mac : String
    property ap_id : String
    property ssid : String
    property wlan_id : String
    property psk_id : String?

    property map_id : String
    # pixels
    property x : Float64
    property y : Float64
    property x_m : Float64?
    property y_m : Float64?
    property num_locating_aps : Int32

    # meters
    @[JSON::Field(key: "accuracy")]
    property raw_accuracy : Int32?

    def accuracy
      return raw_accuracy if raw_accuracy
      15 // num_locating_aps
    end

    property is_guest : Bool?
    property guest : Guest?
  end

  struct ClientStats
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property mac : String
    property last_seen : Int64

    property username : String?
    property hostname : String?
    property os : String?
    property manufacture : String?
    property family : String?
    property model : String?

    @[JSON::Field(key: "ip")]
    property ip_address : String
    property ap_mac : String
    property ap_id : String
    property ssid : String
    property wlan_id : String
    property psk_id : String?

    property is_guest : Bool?
    property guest : Guest?
  end

  struct ClientLocation
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property mac : String
    property map_id : String

    # pixels
    property x : Float64
    property y : Float64
    property x_m : Float64?
    property y_m : Float64?
    property num_locating_aps : Int32

    # meters
    @[JSON::Field(key: "accuracy")]
    property raw_accuracy : Int32?

    def accuracy
      return raw_accuracy if raw_accuracy
      15 // num_locating_aps
    end
  end

  class Guest
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property authorized : Bool
    property authorized_time : Int64?
    property authorized_expiring_time : Int64?
    property name : String?
    property email : String?
    property company : String?
  end

  abstract class WebhookEvent
    include JSON::Serializable

    use_json_discriminator "topic", {
      "location"            => LocationEvents,
      "zone"                => OtherEvents,
      "asset-raw"           => OtherEvents,
      "device-events"       => OtherEvents,
      "device-updowns"      => OtherEvents,
      "alarms"              => OtherEvents,
      "audits"              => OtherEvents,
      "client-join"         => OtherEvents,
      "client-sessions"     => OtherEvents,
      "ping"                => OtherEvents,
      "occupancy-alerts"    => OtherEvents,
      "sdkclient-scan-data" => OtherEvents,
    }
  end

  class LocationEvents < WebhookEvent
    getter topic : String = "location"
    getter events : Array(LocationEvent)
  end

  # we are currently ignoring this event
  class OtherEvents < WebhookEvent
    getter topic : String
    getter events : Array(JSON::Any)
  end

  abstract class LocationEvent
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property site_id : String
    property map_id : String

    property x : Float64
    property y : Float64
    property timestamp : Int64

    use_json_discriminator "type", {
      "sdk"   => LocationSDK,
      "wifi"  => LocationWifi,
      "asset" => LocationAsset,
    }
  end

  class LocationSDK < LocationEvent
    getter type : String = "sdk"
    property name : String?
    property id : String
  end

  class LocationWifi < LocationEvent
    getter type : String = "wifi"
    property mac : String
  end

  class LocationAsset < LocationEvent
    getter type : String = "asset"
    property mac : String

    property ibeacon_uuid : String?
    property ibeacon_major : Int64?
    property ibeacon_minor : Int64?

    property eddystone_uid_namespace : String?
    property eddystone_uid_instance : String?
    property eddystone_url_url : String?

    # BLE manufacturing company ID
    property mfg_company_id : Int64?

    # BLE manufacturing data in hex byte-string format
    property mfg_data : String?

    property battery_voltage : Float64?
  end
end
