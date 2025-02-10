require "placeos-driver/spec"

DriverSpecs.mock_driver "InnerRange::IntegritiHIDVirtualPass" do
  system({
    StaffAPI:  {StaffAPIMock},
    Integriti: {IntegritiMock},
  })

  exec(:has_virtual_card?, user_id: "user-123").get.try(&.as_bool?).should_not be_true
  exec(:request_virtual_card, user_id: "user-123").get
  exec(:has_virtual_card?, user_id: "user-123").get.try(&.as_bool?).should be_true
  exec(:remove_virtual_card, user_id: "user-123").get
  exec(:has_virtual_card?, user_id: "user-123").get.try(&.as_bool?).should_not be_true
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  def user(id : String)
    {
      email:      "user@email.com",
      login_name: "user@email.com",
    }
  end
end

# :nodoc:
class IntegritiMock < DriverSpecs::MockDriver
  @users = {
    "U35" => {
      "id"   => 281474976710691,
      "name" => "Isaiah Langer",
      "site" => {
        id:   1,
        name: "PlaceOS",
      },
      "address"      => "U35",
      "partition_id" => 0,
      "not_origo"    => false, # just so the hash accepts bools
      "email"        => "user@email.com",
    },
  }

  def user_id_lookup(email : String) : Array(String)
    email = email.downcase
    @users.compact_map do |(id, user)|
      user["address"].as(String) if user["email"] == email
    end
  end

  def users(site_id : Int32? = nil, email : String? = nil)
    email = email.try(&.downcase)
    @users.values.select { |user| user["email"] == email }
  end

  def update_entry(type : String, id : String, fields : Hash(String, Bool), attribute : String = "Address", return_object : Bool = false)
    raise "unexpected type #{type}" unless type == "User"
    user = @users[id]
    fields.each do |field, value|
      field = "origo" if field == "cf_HasVirtualCard"
      user[field] = value
    end
  end
end
