require "json"

module Crestron
  # TSW-70 Series Touch Screen Models

  struct DeviceInfo
    include JSON::Serializable

    @[JSON::Field(key: "Model")]
    property model : String?

    @[JSON::Field(key: "Category")]
    property category : String?

    @[JSON::Field(key: "Manufacturer")]
    property manufacturer : String?

    @[JSON::Field(key: "ModelId")]
    property model_id : String?

    @[JSON::Field(key: "DeviceId")]
    property device_id : String?

    @[JSON::Field(key: "SerialNumber")]
    property serial_number : String?

    @[JSON::Field(key: "Name")]
    property name : String?

    @[JSON::Field(key: "DeviceVersion")]
    property device_version : String?

    @[JSON::Field(key: "PufVersion")]
    property puf_version : String?

    @[JSON::Field(key: "BuildDate")]
    property build_date : String?

    @[JSON::Field(key: "Devicekey")]
    property device_key : String?

    @[JSON::Field(key: "MacAddress")]
    property mac_address : String?

    @[JSON::Field(key: "RebootReason")]
    property reboot_reason : String?

    @[JSON::Field(key: "Version")]
    property version : String?
  end
end
