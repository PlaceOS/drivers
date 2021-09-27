require "json"

module AmberTech
  enum Status
    Stop
    Opening
    Opened
    Closing
    Closed
  end

  class DevInfo
    include JSON::Serializable

    getter ver : String
    getter id : String
    getter ip : String

    @[JSON::Field(key: "sub")]
    getter ip_subnet : String

    @[JSON::Field(key: "gw")]
    getter ip_gateway : String
    getter name : String
    getter pass : String?
    getter pass2 : String?
    getter status : Status
  end

  class Devices
    include JSON::Serializable

    @[JSON::Field(key: "devInfo")]
    getter device_info : Array(DevInfo)

    @[JSON::Field(key: "currentIp")]
    getter current_ip : String
  end

  class StatusResp
    include JSON::Serializable

    getter status : Status
  end
end
