require "json"

# Vergesense Data Models
module Vergesense
  struct Building
    include JSON::Serializable

    property name : String
    property building_ref_id : String
    property address : String?
  end

  struct BuildingWithFloors
    include JSON::Serializable

    property building_ref_id : String
    property floors : Array(Floor)
  end

  struct Floor
    include JSON::Serializable

    property floor_ref_id : String
    property name : String
    property capacity : UInt32?
    property max_capacity : UInt32?
    property spaces : Array(Space)
  end

  struct Sensor
    include JSON::Serializable

    property units : String
    property value : Float64
  end

  struct Environment
    include JSON::Serializable

    property sensor : String
    property timestamp : Time

    property humidity : Sensor
    property iaq : Sensor?
    property temperature : Sensor
  end

  class Space
    include JSON::Serializable

    property building_ref_id : String?
    property floor_ref_id : String?
    property space_ref_id : String?
    property space_type : String?
    property name : String?
    property capacity : UInt32?
    property max_capacity : UInt32?
    # property geometry : Geometry?
    property people : People?
    property environment : Environment?
    property timestamp : Time?
    property motion_detected : Bool?

    def floor_key
      "#{building_ref_id}-#{floor_ref_id}".strip
    end

    def ref_id
      self.space_ref_id || self.floor_ref_id || self.space_type
    end
  end

  struct Geometry
    include JSON::Serializable

    property type : String
    property coordinates : Array(Array(Array(Float64)))
  end

  struct People
    include JSON::Serializable

    property count : UInt32?
    # property coordinates : Array(Array(Float64)?)?
  end
end
