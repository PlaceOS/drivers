require "json"

module Lutron
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
    property type : CommuniqueType

    @[JSON::Field(key: "Header")]
    property header : Hash(String, String)

    @[JSON::Field(key: "Body", converter: String::RawConverter)]
    property body : String { "" }

    delegate :[], :[]?, :[]=, to: @header

    def name?
      header["Url"]?
    end

    def initialize(@type, @header, body = nil)
      case body
      when String, Nil
        @body = body
      else
        @body = body.to_json
      end
    end

    def initialize(
      url : String,
      @type = CommuniqueType::ReadRequest,
      body = nil,
      @header = {} of String => String,
    )
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


end
