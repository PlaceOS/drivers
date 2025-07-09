# # Generated from location.proto for location
require "protobuf"

module HPE::ANW::Location
  enum TargetDevType
    TARGET_TYPE_UNKNOWN = 0
    TARGET_TYPE_STATION = 1
    TARGET_TYPE_ROGUE   = 3
  end
  enum Algorithm
    ALGORITHM_TRIANGULATION = 0
  end
  enum MeasurementUnit
    METERS = 0
    FEET   = 1
  end
  enum ZoneEvent
    ZONE_IN  = 0
    ZONE_OUT = 1
  end

  struct MacAddress
    include ::Protobuf::Message

    contract_of "proto2" do
      optional :addr, :bytes, 1
    end
  end

  struct StreamLocation
    include ::Protobuf::Message

    contract_of "proto2" do
      optional :sta_location_x, :float, 1
      optional :sta_location_y, :float, 2
      optional :error_level, :uint32, 3
      optional :loc_algorithm, Algorithm, 9
      optional :unit, MeasurementUnit, 14
      required :sta_eth_mac, MacAddress, 15
      optional :campus_id_string, :string, 16
      optional :building_id_string, :string, 17
      optional :floor_id_string, :string, 18
      optional :target_type, TargetDevType, 19
      optional :associated, :bool, 20
    end
  end

  struct StreamGeofenceNotify
    include ::Protobuf::Message

    contract_of "proto2" do
      optional :geofence_event, ZoneEvent, 1
      optional :geofence_id, :bytes, 2
      optional :geofence_name, :string, 3
      optional :sta_eth_mac, MacAddress, 4
      optional :associated, :bool, 5
      optional :dwell_time, :uint32, 6, default: 0_u32
      optional :hashed_sta_eth_mac, :string, 7
    end
  end
end
