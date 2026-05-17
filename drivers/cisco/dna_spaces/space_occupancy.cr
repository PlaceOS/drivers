require "./events"
require "./location"

struct Cisco::DNASpaces::Space
  include JSON::Serializable

  getter id : String
  getter name : String

  property mac_address : String { id }

  # for compatibility with webex telemetary
  def device_name
    name
  end

  @[JSON::Field(key: "floorId")]
  getter floor_id : String

  # typically ROOM, guessing something like ENTRANCE
  getter type : String
  getter capacity : Int32?

  # typically PEOPLE_COUNT, guessing the other is PRESENCE
  @[JSON::Field(key: "occupancyType")]
  getter occupancy_type : String
end

class Cisco::DNASpaces::SpaceOccupancy
  include JSON::Serializable

  property location : Location
  property space : Space

  # not sure what these fields are for
  # "windowStartTimestamp": 1778556600000,
  # "windowStartDateTime": "2026-05-12T11:30",
  # "timeZone": "Australia/Perth",

  @[JSON::Field(key: "peopleCount")]
  getter people_count : Int32?

  @[JSON::Field(key: "peoplePresence")]
  getter presence : Bool?

  @[JSON::Field(key: "bookingStatus")]
  getter booked : Bool?

  @[JSON::Field(key: "peakPeopleCount")]
  getter peak_people_count : Int32?

  # for compatibility with webex_telemetry
  def humidity : Float64?
  end

  def air_quality : Float64?
  end

  def temperature : Float64?
  end

  def ambient_noise : Float64?
  end

  @[JSON::Field(ignore: true)]
  property last_seen : Int64 = 0_i64

  def device
    space
  end

  def has_position? : Bool
    true
  end

  @[JSON::Field(ignore: true)]
  property map_id : String = ""

  def visit_id
    nil
  end

  def raw_user_id : String
    ""
  end

  def binding(type : SensorType, mac : String)
    case type
    when .presence?
      "#{mac}->presence"
    when .people_count?
      "#{mac}->people_count"
    end
  end

  @[JSON::Field(ignore: true)]
  @location_mappings : Hash(String, String)? = nil

  # Ensure we only process these once
  def location_mappings : Hash(String, String)
    if mappings = @location_mappings
      mappings
    else
      mappings = location.details
      @location_mappings = mappings
      mappings
    end
  end
end
