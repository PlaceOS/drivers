require "placeos-driver"

class Place::UserGroupMappings < PlaceOS::Driver
  descriptive_name "User Group Mappings"
  generic_name :UserGroupMappings
  description "monitors user logins and maps relevent groups to the local user profile"

  accessor staff_api : StaffAPI_1
  accessor calendar_api : Calendar_1

  # NOTE:: user_sys_admin, user_support sets the users persmissions flags
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
      "ad_group3_id" => {
        place_id:    "user_sys_admin",
        description: "this is a special group that sets place users as sys_admins",
      },
    },

    # Group name prefix => group mappings
    group_prefix: {
      "group_name_prefix_" => {
        strip_prefix: false,
        place_id:     "optional-place-id",
      },
    },

    # authority id
    authority_id: "authority-12345",
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

  @authority_id : Array(String) = [] of String
  @group_mappings : Hash(String, Mapping) = {} of String => Mapping
  @group_prefixes : Hash(String, Prefix) = {} of String => Prefix
  @users_checked : UInt64 = 0_u64
  @error_count : UInt64 = 0_u64

  def on_update
    @group_mappings = setting?(Hash(String, Mapping), :group_mappings) || {} of String => Mapping
    @group_prefixes = setting?(Hash(String, Prefix), :group_prefix) || {} of String => Prefix
    @group_prefixes = @group_prefixes.transform_keys(&.downcase)

    authority_id = setting?(String | Array(String), :authority_id) || "authority-12345"
    case authority_id
    in String
      @authority_id = [authority_id]
    in Array(String)
      @authority_id = authority_id
    end
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
    user_json = staff_api.user(id).get
    auth_id = user_json["authority_id"].as_s
    return unless auth_id.in?(@authority_id)
    sync_user(user_json)
  end

  protected def sync_user(user_json)
    # Loading the existing user info in PlaceOS (we need the users id)
    user = NamedTuple(id: String, email: String, login_name: String?).from_json user_json.to_json
    email = user[:login_name].presence || user[:email]
    logger.debug { "found placeos user info: #{user[:email]}, id #{user[:email]}" }

    # Request user details from GraphAPI or Google    
    begin
      users_groups = calendar_api.get_groups(email).get
    rescue error
      if u = calendar_api.get_user(email).get
        users_groups = calendar_api.get_groups(u["id"]).get
      else
        u = calendar_api.list_users(email, 1).get.as_a.first
        users_groups = calendar_api.get_groups(u["id"]).get
      end
    end

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
    staff_api.update_user(user[:id], {groups: groups}.to_json).get

    logger.debug { "checked #{users_groups.size}, found #{groups.size} matching: #{groups}" }
  end

  @syncing : Bool = false

  @[PlaceOS::Driver::Security(Level::Support)]
  def sync_all_users
    @authority_id.each do |auth_id|
      sync_users(auth_id)
    end
  end

  protected def sync_users(authority_id)
    return "currently syncing" if @syncing
    @syncing = true

    limit = 100
    offset = 0

    issues_with = [] of String

    loop do
      users = staff_api.query_users(
        limit: limit,
        offset: offset,
        authority_id: authority_id
      ).get.as_a

      logger.debug { "syncing users #{offset}->#{offset + limit}..." }

      # process 20 users a second
      users.each do |user|
        begin
          sync_user(user)
          sleep 50.milliseconds
        rescue error
          issues_with << user["email"].as_s
        end
      end

      break if users.size < limit
      offset += limit
    end

    logger.debug { "sync complete! issues with #{issues_with.size}:\n#{issues_with}" }
    issues_with
  ensure
    @syncing = false
  end
end
