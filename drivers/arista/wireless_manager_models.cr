require "json"
require "uri"

module Arista
  enum Unit
    Feet
    Meter
  end

  struct ID
    include JSON::Serializable

    getter id : Int64
    getter type : String
  end

  struct GeoInfo
    include JSON::Serializable

    getter coordinates : Coordinates
  end

  struct Coordinates
    include JSON::Serializable

    getter lat : Float64
    getter lng : Float64
    # getter altitude : Int32
  end

  class Location
    include JSON::Serializable

    getter type : String
    getter name : String

    @[JSON::Field(key: "id")]
    getter loc_id : ID

    @[JSON::Field(key: "accessibleToUser")]
    getter visible : Bool

    @[JSON::Field(key: "timezoneId")]
    getter timezone : String?

    # "{\"coordinates\": {\"lat\": -37.78754839955705, \"lng\": 175.32221218440074, \"altitude\": 0}}"
    @[JSON::Field(key: "geoInfo")]
    getter geo_info_raw : String?

    getter children : Array(Location) { [] of Location }

    @[JSON::Field(ignore_deserialize: true)]
    property parent_id : Int64? = nil

    def geo_info : Coordinates?
      json = geo_info_raw
      return unless json

      GeoInfo.from_json(json).coordinates
    end

    def id
      loc_id.id
    end

    def flatten : Array(Location)
      result = [self]
      children.each do |child|
        child.parent_id = self.id
        result.concat(child.flatten)
      end
      children.clear
      result
    end
  end

  struct LocationsRequest
    include JSON::Serializable

    @[JSON::Field(key: "nextLink")]
    getter next_link : String?

    @[JSON::Field(key: "pollingUrl")]
    getter result_url : String

    @[JSON::Field(key: "deviceCount")]
    getter page_size : Int32

    @[JSON::Field(key: "totalDeviceCount")]
    getter total_results : Int32

    def next_uri : URI?
      if url = next_link
        URI.parse(url)
      end
    end
  end

  struct LocationTracking
    include JSON::Serializable

    @[JSON::Field(key: "locationTrackingResult")]
    getter results : Array(LocationResult)
  end

  struct LocationResult
    include JSON::Serializable

    @[JSON::Field(key: "devicesType")]
    getter type : String

    @[JSON::Field(key: "locationId")]
    getter location : ID

    getter clients : Array(ClientDetails)
  end

  struct ClientDetails
    include JSON::Serializable

    getter device : ClientDevice
    getter position : ClientPosition
    getter proximity : Array(ClientProximity)
  end

  struct ClientDevice
    include JSON::Serializable

    @[JSON::Field(key: "locationId")]
    getter location : ID

    @[JSON::Field(key: "boxId")]
    getter box_id : Int64
    getter name : String

    @[JSON::Field(key: "userName")]
    getter username : String?

    # "Android"
    @[JSON::Field(key: "osType")]
    getter os : String?

    @[JSON::Field(key: "macAddress")]
    getter macaddress : String

    @[JSON::Field(key: "vlanId")]
    getter macaddress : Int64?

    @[JSON::Field(key: "ipAddress")]
    getter ip_v4 : String?

    @[JSON::Field(key: "ipv6Addresses")]
    getter ip_v6 : Array(String)?
  end

  struct ClientPosition
    include JSON::Serializable

    struct Coordinates
      include JSON::Serializable

      getter unit : Unit

      @[JSON::Field(key: "xCordinate")]
      getter x : Float64

      @[JSON::Field(key: "yCordinate")]
      getter y : Float64

      @[JSON::Field(key: "xPosition")]
      getter x_pos : Float64

      @[JSON::Field(key: "yPosition")]
      getter y_pos : Float64
    end

    @[JSON::Field(key: "errorCode")]
    getter error : String?

    # nil if there is an error
    getter coordinates : Coordinates?
  end

  struct ClientProximity
    include JSON::Serializable

    struct ObservedDeviceDistance
      include JSON::Serializable

      struct Distance
        include JSON::Serializable

        getter value : Float64
        getter unit : Unit
      end

      getter min : Distance
      getter max : Distance
    end

    struct ObservingDevice
      include JSON::Serializable

      @[JSON::Field(key: "locationId")]
      getter location : ID

      @[JSON::Field(key: "boxId")]
      getter box_id : Int64
      getter name : String
      getter macaddress : String
    end

    @[JSON::Field(key: "observedDeviceDistance")]
    getter distance : ObservedDeviceDistance

    @[JSON::Field(key: "observingDevice")]
    getter device : ObservingDevice
  end
end
