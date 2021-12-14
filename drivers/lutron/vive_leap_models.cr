require "json"

module Lutron
  macro upper_enum(name)
    {% if name.type.resolve.nilable? %} @{{name.var}} : String? {% else %} @{{name.var}} : String {% end %}
    {% enum_type = name.type.resolve.union_types.reject(&.nilable?).first %}

    def {{name.var}} : {{name.type}}
      if value = @{{name.var}}
        {{enum_type}}.parse(value)
      else
        nil
      end
    end

    def {{name.var}}=(value : {{name.type}}) : {{name.type}}
      @{{name.var}} = value.try &.to_s
      value
    end
  end

  enum CommuniqueType
    ReadRequest
    ReadResponse
    UpdateRequest
    UpdateResponse
    SubscribeRequest
    SubscribeResponse
    DeleteRequest
    DeleteResponse
    CreateRequest
    CreateResponse
    UnsubscribeRequest
    UnsubscribeResponse
    ExceptionResponse
  end

  class Request
    include JSON::Serializable

    @[JSON::Field(key: "CommuniqueType")]
    Lutron.upper_enum type : CommuniqueType

    @[JSON::Field(key: "Header")]
    property header : Hash(String, String)

    @[JSON::Field(key: "Body", converter: String::RawConverter)]
    property body : String { "" }

    delegate :[], :[]?, :[]=, to: @header

    def name?
      header["Url"]?
    end

    def initialize(
      url : String,
      req_type : CommuniqueType = CommuniqueType::ReadRequest,
      body = nil,
      @header = {} of String => String
    )
      @type = req_type.to_s
      @body = case body
              when String, Nil
                body
              else
                body.to_json
              end
      header["Url"] = url
    end
  end

  struct ClientSetting
    include JSON::Serializable

    @[JSON::Field(key: "ClientSetting")]
    getter protocol : ClientVersion
  end

  struct ClientVersion
    include JSON::Serializable

    @[JSON::Field(key: "ClientMajorVersion")]
    getter major_version : Int32

    @[JSON::Field(key: "ClientMinorVersion")]
    getter minor_version : Int32

    def version
      "#{major_version}.#{minor_version}.0"
    end
  end

  struct ExceptionDetail
    include JSON::Serializable

    @[JSON::Field(key: "Message")]
    getter message : String

    @[JSON::Field(key: "ErrorCode")]
    getter error_code : Int32?
  end

  struct MultipleAreaStatus
    include JSON::Serializable

    @[JSON::Field(key: "AreaStatuses")]
    getter states : Array(AreaStatus)
  end

  enum OccupancyStatus
    Occupied
    Unoccupied
    Unknown
  end

  struct AreaStatus
    include JSON::Serializable

    # /area/3/status
    getter href : String

    @[JSON::Field(key: "Level")]
    getter level : Float64?

    @[JSON::Field(key: "OccupancyStatus")]
    Lutron.upper_enum occupancy : OccupancyStatus?

    def status_key
      _blank, component, area_id, status = href.split("/", 4)
      "#{component}#{area_id}"
    end
  end

  struct MultipleZoneStatus
    include JSON::Serializable

    @[JSON::Field(key: "ZoneStatuses")]
    getter states : Array(ZoneStatus)
  end

  struct OneZoneStatus
    include JSON::Serializable

    @[JSON::Field(key: "ZoneStatus")]
    getter status : ZoneStatus
  end

  enum SwitchedLevel
    On
    Off
  end

  enum ContactClosureState
    Open
    Closed
  end

  enum Availability
    Available
    Unavailable
    Unknown
  end

  struct ZoneStatus
    include JSON::Serializable

    getter href : String

    @[JSON::Field(key: "Level")]
    getter level : Float64?

    @[JSON::Field(key: "SwitchedLevel")]
    Lutron.upper_enum switched_level : SwitchedLevel?

    @[JSON::Field(key: "Availability")]
    Lutron.upper_enum availability : Availability?

    @[JSON::Field(key: "CCOLevel")]
    Lutron.upper_enum contact_closure : ContactClosureState?

    def status_key
      _blank, component, zone_id, status = href.split("/", 4)
      "#{component}#{zone_id}"
    end
  end
end
