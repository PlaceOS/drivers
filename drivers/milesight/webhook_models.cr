require "json"

module Milesight
  struct WebhookPayload
    include JSON::Serializable

    @[JSON::Field(key: "applicationID")]
    getter app_id : String

    @[JSON::Field(key: "applicationName")]
    getter app_name : String

    @[JSON::Field(key: "deviceName")]
    getter device_name : String

    @[JSON::Field(key: "devEUI")]
    getter dev_eui : String

    getter time : Time
    getter data : String
  end
end
