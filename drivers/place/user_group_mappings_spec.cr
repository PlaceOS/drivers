require "placeos-driver/spec"

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def user(id : String)
    {email: "steve@placeos.tech"}
  end

  def update_user(id : String, body_json : String) : Nil
    self[id] = body_json
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def get_groups(user_id : String)
    [
      {
        id:          "5f4694-96f3-4209-a432-b04ac06ca7",
        name:        "Azure-Global-Microsoft Intune Users-Licensed",
        description: "Azure-Global-Microsoft Intune Users-Licensed",
      },
      {
        id:          "bb8836-5942-402d-8d67-55b1a642",
        name:        "All Users",
        description: "Auto generated group, do not change",
      },
    ]
  end
end

DriverSpecs.mock_driver "Place::LogicExample" do
  system({
    StaffAPI: {StaffAPIMock},
    Calendar: {CalendarMock},
  })

  settings({
    group_mappings: {
      "5f4694-96f3-4209-a432-b04ac06ca7" => {"place_id" => "intune"},
      "admins"                           => {"place_id" => "im an admin"},
    },
  })

  exec(:check_user, "user-1234").get
  system(:StaffAPI_1)["user-1234"].should eq({"groups" => ["intune"]}.to_json)
end
