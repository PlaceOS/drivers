require "json"
require "../dna_spaces"
require "./location"
require "./device"
require "./*"

# This is used to map the various events into a simpler data structure
abstract class Cisco::DNASpaces::Events
  include JSON::Serializable

  # event type hint
  use_json_discriminator "eventType", {
    "DEVICE_ENTRY"           => DeviceEntryWrapper,
    "DEVICE_EXIT"            => DeviceExitWrapper,
    "PROFILE_UPDATE"         => ProfileUpdateWrapper,
    "LOCATION_CHANGE"        => LocationChangeWrapper,
    "DEVICE_LOCATION_UPDATE" => DeviceLocationUpdateWrapper,
    "TP_PEOPLE_COUNT_UPDATE" => PeopleCountUpdateWrapper,
    "DEVICE_PRESENCE"        => DevicePresenceWrapper,
    "USER_PRESENCE"          => UserPresenceWrapper,
    "APP_ACTIVATION"         => AppActivactionWrapper,
  }
end

class Cisco::DNASpaces::DeviceEntryWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "DEVICE_ENTRY"

  @[JSON::Field(key: "deviceEntry")]
  getter payload : DeviceEntry
end

class Cisco::DNASpaces::DeviceExitWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "DEVICE_EXIT"

  @[JSON::Field(key: "deviceExit")]
  getter payload : DeviceExit
end

class Cisco::DNASpaces::ProfileUpdateWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "PROFILE_UPDATE"

  @[JSON::Field(key: "deviceProfileUpdate")]
  getter payload : Device
end

class Cisco::DNASpaces::LocationChangeWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "LOCATION_CHANGE"

  @[JSON::Field(key: "locationHierarchyChange")]
  getter payload : LocationChange
end

class Cisco::DNASpaces::DeviceLocationUpdateWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "DEVICE_LOCATION_UPDATE"

  @[JSON::Field(key: "deviceLocationUpdate")]
  getter payload : DeviceLocationUpdate
end

class Cisco::DNASpaces::PeopleCountUpdateWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "TP_PEOPLE_COUNT_UPDATE"

  @[JSON::Field(key: "tpPeopleCountUpdate")]
  getter payload : PeopleCountUpdate
end

class Cisco::DNASpaces::DevicePresenceWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "DEVICE_PRESENCE"

  @[JSON::Field(key: "devicePresence")]
  getter payload : DevicePresence
end

class Cisco::DNASpaces::UserPresenceWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "USER_PRESENCE"

  @[JSON::Field(key: "userPresence")]
  getter payload : UserPresence
end

class Cisco::DNASpaces::AppActivactionWrapper < Cisco::DNASpaces::Events
  getter eventType : String = "APP_ACTIVATION"

  @[JSON::Field(key: "appActivation")]
  getter payload : AppActivaction
end
