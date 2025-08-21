require "placeos-driver/spec"

class PMS < DriverSpecs::MockDriver
  def available_slots
    data = <<-JSON
[
    {
        "DepartmentName": "CMO",
        "DeptId": "af22ac15-b85c-f011-bec2-6045bd69cb6a",
        "NoofParkingSlots": "10",
        "OccupiedParkingSlots": "1",
        "AvailableParkingSlots": "9"
    },
    {
        "DepartmentName": "PMO1111111",
        "DeptId": "e989057d-9460-f011-bec2-6045bd1585f5",
        "NoofParkingSlots": "4",
        "OccupiedParkingSlots": "4",
        "AvailableParkingSlots": "0"
    },
    {
        "DepartmentName": "Solutions21",
        "DeptId": "87336d6a-2d5e-f011-bec1-0022480ce5ed",
        "NoofParkingSlots": "10",
        "OccupiedParkingSlots": "10",
        "AvailableParkingSlots": "0"
    },
    {
        "DepartmentName": "TECHNOLOGY",
        "DeptId": "4a813c24-7a67-f011-bec3-6045bd69cb6a",
        "NoofParkingSlots": "4",
        "OccupiedParkingSlots": "0",
        "AvailableParkingSlots": "4"
    }
]
JSON
    JSON.parse(data)
  end
end

DriverSpecs.mock_driver "PMSLogic" do
  system({
    PMS: {PMS},
  })

  val = exec(:get_parking_status).get.as_a.size.should eq(4)
end
