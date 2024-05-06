require "json"

module KontaktIO
  class Page
    include JSON::Serializable

    getter size : Int32
    getter number : Int32 { 0 }

    @[JSON::Field(key: "totalElements")]
    getter total_elements : Int32 { 0 }

    @[JSON::Field(key: "totalPages")]
    getter total_pages : Int32 { 0 }
  end

  class Response(T)
    include JSON::Serializable

    getter content : Array(T)
    getter page : Page?
  end

  class Tracking
    include JSON::Serializable

    @[JSON::Field(key: "entityId")]
    getter entity_id : Int64?

    @[JSON::Field(key: "entityName")]
    getter entity_name : String?

    @[JSON::Field(key: "trackingId")]
    getter mac_address : String

    @[JSON::Field(key: "startTime")]
    getter start_time : Time

    @[JSON::Field(key: "endTime")]
    getter end_time : Time

    getter contacts : Array(Contact)

    def duration
      contacts.first.duration_sec
    end
  end

  class Contact
    include JSON::Serializable

    @[JSON::Field(key: "entityId")]
    getter entity_id : Int64?

    @[JSON::Field(key: "entityName")]
    getter entity_name : String?

    @[JSON::Field(key: "trackingId")]
    getter mac_address : String

    @[JSON::Field(key: "durationSec")]
    getter duration_sec : Int32
  end

  class Presence
    include JSON::Serializable

    @[JSON::Field(key: "companyId")]
    getter company_id : String

    @[JSON::Field(key: "trackingId")]
    getter mac_address : String

    @[JSON::Field(key: "roomName")]
    getter room_name : String

    @[JSON::Field(key: "roomId")]
    getter room_id : Int64

    @[JSON::Field(key: "floorId")]
    getter floor_id : Int64

    @[JSON::Field(key: "floorName")]
    getter floor_name : String

    @[JSON::Field(key: "buildingId")]
    getter building_id : Int64

    @[JSON::Field(key: "buildingName")]
    getter building_name : String

    @[JSON::Field(key: "campusId")]
    getter campus_id : Int64

    @[JSON::Field(key: "campusName")]
    getter campus_name : String

    @[JSON::Field(key: "startTime")]
    getter start_time : String

    @[JSON::Field(key: "endTime")]
    getter end_time : String
  end

  class Position
    include JSON::Serializable

    @[JSON::Field(key: "trackingId")]
    getter mac_address : String

    @[JSON::Field(key: "roomId")]
    getter room_id : Int64?

    @[JSON::Field(key: "floorId")]
    getter floor_id : Int64?

    @[JSON::Field(key: "buildingId")]
    getter building_id : Int64?

    @[JSON::Field(key: "campusId")]
    getter campus_id : Int64?

    @[JSON::Field(key: "lastUpdate")]
    getter last_update : String?
    getter x : Int64?
    getter y : Int64?
  end

  class BuildingShort
    include JSON::Serializable

    getter id : Int64
    getter name : String
  end

  class Floor
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : Int64
    getter name : String

    getter height : Float64?   # in meters
    getter width : Float64?    # in meters
    getter rotation : Float64? # in radians
    getter level : Int32?

    # lat lng from bottom right corner of image
    @[JSON::Field(key: "anchorLat")]
    getter lat : Float64?

    @[JSON::Field(key: "anchorLng")]
    getter lng : Float64?

    getter building : BuildingShort? = nil
  end

  class Building
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter description : String?
    getter address : String?
    getter lat : Float64?
    getter lng : Float64?

    getter floors : Array(Floor)
  end

  class Campus
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter description : String?
    getter address : String?

    getter timezone : String?
    getter lat : Float64?
    getter lng : Float64?

    getter buildings : Array(Building)
  end

  class Room
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter id : Int64
    getter name : String

    @[JSON::Field(key: "roomType")]
    getter room_type : String
    getter floor : Floor

    @[JSON::Field(key: "roomNumber")]
    getter room_number : Int64?

    @[JSON::Field(key: "roomSensors")]
    getter room_sensors : Array(RoomSensor) { [] of RoomSensor }

    def room_sensor_ids : Array(String)
      room_sensors.map(&.tracking_id)
    end

    def to_room_occupancy(occupied : Bool, last_update : Time)
      RoomOccupancy.new self, occupied, last_update
    end
  end

  struct RoomSensor
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "trackingId")]
    getter tracking_id : String
  end

  struct RoomOccupancy
    include JSON::Serializable

    def initialize(room : Room, occupied : Bool, last_update : Time)
      @room_id = room.id
      @room_name = room.name
      floor = room.floor
      @floor_id = floor.id
      @floor_name = floor.name
      floor.building.try do |building|
        @building_id = building.id
        @building_name = building.name
      end

      @occupancy = occupied ? 1 : 0
      @last_update = last_update
      @pir = true
    end

    @[JSON::Field(key: "roomId")]
    getter room_id : Int64

    @[JSON::Field(key: "roomName")]
    getter room_name : String?

    @[JSON::Field(key: "floorId")]
    getter floor_id : Int64?

    @[JSON::Field(key: "floorName")]
    getter floor_name : String?

    @[JSON::Field(key: "buildingId")]
    getter building_id : Int64? = nil

    @[JSON::Field(key: "buildingName")]
    getter building_name : String? = nil

    @[JSON::Field(key: "campusId")]
    getter campus_id : Int64? = nil

    @[JSON::Field(key: "campusName")]
    getter campus_name : String? = nil

    @[JSON::Field(key: "lastUpdate")]
    getter last_update : Time
    getter occupancy : Int32

    getter? pir : Bool = false
  end

  class Telemetry
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    @[JSON::Field(key: "trackingId")]
    getter id : String

    @[JSON::Field(key: "secondsSincePirMotion")]
    getter seconds_since_motion : Int64?

    @[JSON::Field(key: "numberOfPeopleDetected")]
    getter number_of_people : Int32?

    getter timestamp : Time
  end
end
