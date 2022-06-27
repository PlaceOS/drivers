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

  struct Report
    include JSON::Serializable

    property timestamp : Time
    property person_count : Int32?
    property signs_of_life : Bool?
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
    property last_reports : Array(Report)?
    property environment : Environment?
    property timestamp : Time?
    property motion_detected : Bool?

    def signs_of_life? : Bool?
      if report = last_reports.try &.first?
        report.signs_of_life if report.timestamp >= 2.hours.ago
      end
    end

    # NOTE:: not returned by the API, we fill this in
    property signs_of_life : Bool?

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
