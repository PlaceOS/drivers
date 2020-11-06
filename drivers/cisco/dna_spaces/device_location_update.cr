require "./events"

class DeviceLocationUpdate
  include JSON::Serializable

  @[JSON::Field(key: "ssid")]
  getter ssid : String
end
