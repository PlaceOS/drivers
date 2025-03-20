require "json"

module HPE::ANW::Model
  record AuthToken, expires_in : Int64, token_type : String, refresh_token : String, access_token : String do
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter! expiry : Time

    def after_initialize
      @expiry = Time.utc + expires_in.seconds
    end

    def token
      "#{token_type} #{access_token}"
    end
  end

  struct WifiClientLocations
    include JSON::Serializable

    getter items : Array(WifiClientLocation)
    getter count : Int32
    getter total : Int32

    @[JSON::Field(key: "next")]
    getter _next : Int32
  end

  struct WifiClientLocation
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    getter item_type : String

    getter id : String

    @[JSON::Field(key: "siteId")]
    getter site_id : String?

    @[JSON::Field(key: "buildingId")]
    getter building_id : String?

    @[JSON::Field(key: "floorId")]
    getter floor_id : String?

    @[JSON::Field(key: "macAddress")]
    getter mac_address : String?

    @[JSON::Field(key: "hashedMacAddress")]
    getter hashed_mac_address : String?

    getter associated : Bool?

    @[JSON::Field(key: "associatedBssid")]
    getter associated_bssid : String?

    @[JSON::Field(key: "cartesianCoordinates")]
    getter cartesian_coordinates : CartesianCoordinates?

    @[JSON::Field(key: "geoCoordinates")]
    getter geo_coordinates : GeoCoordinates

    @[JSON::Field(key: "clientClassification")]
    getter client_classification : String

    getter accuracy : Float64

    @[JSON::Field(key: "numOfReportingAps")]
    getter num_of_reporting_aps : Int32

    getter connected : Bool

    @[JSON::Field(key: "createdAt")]
    getter created_at : Time
  end

  struct CartesianCoordinates
    include JSON::Serializable

    getter unit : String

    @[JSON::Field(key: "xPosition")]
    getter x_position : Int32

    @[JSON::Field(key: "yPosition")]
    getter y_position : Int32
  end

  struct GeoCoordinates
    include JSON::Serializable

    getter latitude : Float64
    getter longitude : Float64
  end
end
