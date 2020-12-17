module Place; end

require "oauth2"
require "google"

class Place::UserGroupMappings < PlaceOS::Driver
  descriptive_name "User Group Mappings"
  generic_name :UserGroupMappings
  description "monitors user logins and maps relevent groups to the local user profile"

  accessor staff_api : StaffAPI_1
  accessor calendar_api : Calendar_1

  default_settings({
    # ID => place_name
    group_mappings: {
      "group_id"  => "manager",
      "group2_id" => "boss",
    },
  })

  class UserLogin
    include JSON::Serializable

    property user_id : String
    property provider : String
  end

  def on_load
    monitor("auth/login") { |_subscription, payload| new_user_login(payload) }
    on_update
  end

  @group_mappings : Hash(String, String) = {} of String => String
  @users_checked : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  def on_update
    @group_mappings = setting?(Hash(String, String), :group_mappings) || {} of String => String
  end

  protected def new_user_login(user_json)
    user_details = UserLogin.from_json user_json
    check_user(user_details.user_id)

    @users_checked += 1
    self[:users_checked] = @users_checked
  rescue error
    logger.error { error.inspect_with_backtrace }
    self[:last_error] = {
      error: error.message,
      time:  Time.local.to_s,
      user:  user_json,
    }
    @error_count += 1
    self[:error_count] = @error_count
  end

  @[Security(Level::Support)]
  def check_user(id : String) : Nil
    logger.debug { "checking groups of: #{id}" }

    # Loading the existing user info in PlaceOS (we need the users id)
    email = staff_api.user(id).get["email"].as_s
    logger.debug { "found placeos user info: #{email}" }

    # Request user details from GraphAPI or Google
    users_groups = calendar_api.get_groups(email).get
    logger.debug { "found user groups: #{users_groups.to_pretty_json}" }
    users_groups = users_groups.as_a.map { |group| group["id"].as_s }

    # Build the list of placeos groups based on the mappings and update the user model
    groups = [] of String
    @group_mappings.each { |group_id, place_group| groups << place_group if users_groups.includes? group_id }
    staff_api.update_user(id, {groups: groups}.to_json).get
  end
end
