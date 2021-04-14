module Place; end

class Place::UserGroupMappings < PlaceOS::Driver
  descriptive_name "User Group Mappings"
  generic_name :UserGroupMappings
  description "monitors user logins and maps relevent groups to the local user profile"

  accessor staff_api : StaffAPI_1
  accessor calendar_api : Calendar_1

  default_settings({
    # ID => place_name
    group_mappings: {
      "group_id" => {
        place_id:    "manager",
        description: "managers of the level2 building",
      },
      "group2_id" => {
        place_id:    "boss",
        description: "people that can access everything",
      },
    },

    # Group name prefix => group mappings
    group_prefix: {
      "group_name_prefix_" => {
        strip_prefix: false,
        place_id:     "optional-place-id",
      },
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

  alias Mapping = NamedTuple(place_id: String)
  alias Prefix = NamedTuple(strip_prefix: Bool?, place_id: String?)

  @group_mappings : Hash(String, Mapping) = {} of String => Mapping
  @group_prefixes : Hash(String, Prefix) = {} of String => Prefix
  @users_checked : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  def on_update
    @group_mappings = setting?(Hash(String, Mapping), :group_mappings) || {} of String => Mapping
    @group_prefixes = setting?(Hash(String, Prefix), :group_prefix) || {} of String => Prefix
    @group_prefixes = @group_prefixes.transform_keys(&.downcase)
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
    user = NamedTuple(email: String, login_name: String?).from_json staff_api.user(id).get.to_json
    email = user[:login_name].presence || user[:email]
    logger.debug { "found placeos user info: #{user[:email]}, id #{user[:email]}" }

    # Request user details from GraphAPI or Google
    users_groups = calendar_api.get_groups(email).get
    logger.debug { "found user groups: #{users_groups.to_pretty_json}" }
    users_groups = users_groups.as_a

    users_group_ids = users_groups.map { |group| group["id"].as_s }
    users_group_names = users_groups.map { |group| group["name"].as_s.downcase }

    # Build the list of placeos groups based on the mappings and update the user model
    groups = [] of String
    @group_mappings.each { |group_id, place_group| groups << place_group[:place_id] if users_group_ids.includes? group_id }
    @group_prefixes.each do |group_prefix, place_group|
      users_group_names.each do |name|
        if name.starts_with?(group_prefix)
          if place_name = place_group[:place_id]
            groups << place_name
          elsif place_group[:strip_prefix]
            groups << name.split(group_prefix, 2)[-1]
          else
            groups << name
          end
        end
      end
    end
    staff_api.update_user(id, {groups: groups}.to_json).get

    logger.debug { "checked #{users_groups.size}, found #{groups.size} matching: #{groups}" }
  end
end
