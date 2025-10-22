require "placeos-driver"

class PMSLogic < PlaceOS::Driver
  descriptive_name "Parking Management System Logic"
  generic_name :PMSLogic
  description "Abstracts Parking slots access for PMS"

  default_settings({
    poll_every_seconds: 300,
  })

  accessor pms : PMS_1
  
  def on_update
    poll_every_seconds : Int32 = setting?(Int32, :poll_every_seconds) || 300
    schedule.clear
    schedule.every(poll_every_seconds.seconds) { get_parking_status }
  end

  def get_parking_status
    parking_slots = Array(ParkingStatus).from_json(pms.available_slots.get.to_json)
    self[:parking_slots_status] = parking_slots
    parking_slots
  end

  struct ParkingStatus
    include JSON::Serializable

    @[JSON::Field(key: "DeptId", ignore_serialize: true)]
    getter dept_id : String

    getter(department_id : String) { dept_id }

    @[JSON::Field(key: "DepartmentName", ignore_serialize: true)]
    getter dept_name : String

    getter(department_name : String) { dept_name }

    @[JSON::Field(key: "NoofParkingSlots", ignore_serialize: true)]
    getter no_of_slots : String

    getter(total_parking_slots : Int32) { no_of_slots.to_i }

    @[JSON::Field(key: "OccupiedParkingSlots", ignore_serialize: true)]
    getter occupied_slots : String

    getter(occupied_parking_slots : Int32) { occupied_slots.to_i }

    @[JSON::Field(key: "AvailableParkingSlots", ignore_serialize: true)]
    getter available_slots : String

    getter(available_parking_slots : Int32) { available_slots.to_i }

    def after_initialize
      department_id
      department_name
      total_parking_slots
      occupied_parking_slots
      available_parking_slots
    end
  end
end
