require "placeos-driver"
require "place_calendar"
require "xml"
require "set"

require "../place/models/workplace_subscriptions"

class InnerRange::IntegritiUserSync < PlaceOS::Driver
  include Place::WorkplaceSubscription

  descriptive_name "Integriti User Sync"
  generic_name :IntegritiUserSync

  default_settings({
    user_group_id:            "building@org.com",
    sync_cron:                "0 21 * * *",
    integriti_security_group: "QG15",

    _csv_sync_mappings: {
      parking: {
        default: "unisex with parking",
        female:  "Female with parking",
        male:    "Male with parking",
      },
      default: {
        default: "unisex without parking",
        female:  "Female without parking",
        male:    "Male without parking",
      },
    },

    # use these for enabling push notifications
    _push_authority:        "authority-GAdySsf05mL",
    _push_notification_url: "https://placeos-dev.aca.im/api/engine/v2/notifications/office365",
  })

  accessor directory : Calendar_1
  accessor integriti : Integriti_1
  accessor staff_api : StaffAPI_1

  @time_zone : Time::Location = Time::Location.load("GMT")

  @syncing : Bool = false
  @sync_mutex : Mutex = Mutex.new
  @sync_requests : Int32 = 0

  getter csv_sync_mappings : Hash(String, Hash(String, String))? = nil

  def on_update
    @time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(@time_zone_string)

    @sync_cron = setting?(String, :sync_cron).presence || "0 21 * * *"
    @user_group_id = setting(String, :user_group_id)
    @integriti_security_group = setting(String, :integriti_security_group)

    @csv_sync_mappings = setting?(Hash(String, Hash(String, String)), :csv_sync_mappings)

    @graph_group_id = nil

    schedule.clear
    schedule.cron(@sync_cron, @time_zone) { sync_users }

    if setting?(String, :push_notification_url).presence
      push_notificaitons_configure
    end
  end

  getter graph_group_id : String do
    if user_group_id.includes?('@')
      directory.get_group(user_group_id).get["id"].as_s
    else
      user_group_id
    end
  end

  getter time_zone_string : String = "GMT"
  getter sync_cron : String = "0 21 * * *"

  getter! user_group_id : String
  getter! integriti_security_group : String

  class ::PlaceCalendar::Member
    property next_page : String? = nil
  end

  alias DirUser = ::PlaceCalendar::Member

  protected def normalize_number_plate(plate : String, *plates)
    new_plates = Set(String).new(plate.split(',').map(&.strip.gsub(/[^A-Za-z0-9]/, "").upcase))
    plates.each do |existing_plate|
      next unless existing_plate
      new_plates.concat existing_plate.split(',')
    end
    new_plates.join(',')
  end

  # email => licence plate
  def building_parking_users : Hash(String, String)
    parking_access = Hash(String, String).new
    users = staff_api.metadata(building_id, "parking-users").get.dig?("parking-users", "details")
    return parking_access unless users

    users.as_a.each do |user|
      begin
        next if user["deny"].as_bool?
        email = user["email"].as_s.strip.downcase
        plate = normalize_number_plate user["plate_number"].as_s
        parking_access[email] = plate
      rescue error
        logger.error(exception: error) { "failed to parse user #{user}" }
      end
    end

    parking_access
  end

  def perform_user_sync
    return "already syncing" if @syncing

    @sync_mutex.synchronize do
      begin
        @syncing = true
        @sync_requests = 0
        sync_users
      ensure
        @syncing = false
      end
    end

    spawn { perform_user_sync } if @sync_requests > 0
  end

  protected def sync_users
    # get the list of users in the integriti permissions group: (i.e. QG2)
    email_to_user_id = integriti.managed_users_in_group(integriti_security_group).get.as_h.transform_values(&.as_s)
    logger.debug { "Number of users in Integrity security group: #{email_to_user_id.size}" }

    ad_emails = [] of String
    new_users = [] of DirUser

    # get the list of users in the active directory (page by page)
    users = Array(DirUser).from_json directory.get_members(user_group_id).get.to_json
    loop do
      # keep track of users that need to be created
      users.each do |user|
        unless user.suspended
          user_email = user.email.strip.downcase
          user.email = user_email
          username = user.username.strip.downcase
          user.username = username
          # handle cases where email may not equal username (and already configured in the system)
          user_id = email_to_user_id[username]?
          if user_id.nil? && username != user_email
            if user_id = email_to_user_id[user_email]?
              email_to_user_id[username] = user_id
            end
          end
          ad_emails << username
          new_users << user unless user_id
        end
      end

      next_page = users.first?.try(&.next_page)
      break unless next_page

      # ensure we don't blow any request limits
      logger.debug { "fetching next page..." }
      sleep 500.milliseconds
      users = Array(DirUser).from_json directory.get_members(user_group_id, next_page).get.to_json
    end

    logger.debug { "Number of users in Integrity security group: #{email_to_user_id.size}" }
    logger.debug { "Number of users in Directory security group: #{ad_emails.size}" }

    # find all the users that need to be removed from the group
    removed = 0
    removed_errors = 0

    remove_emails = email_to_user_id.keys - ad_emails
    remove_emails.each do |email|
      begin
        user_id = email_to_user_id[email]
        integriti.modify_user_permissions(
          user_id: user_id,
          group_id: integriti_security_group,
          add: false,
          externally_managed: true
        ).get
        removed += 1
      rescue error
        removed_errors += 1
        logger.warn(exception: error) { "failed to remove group #{user_group_id} from #{email}" }
      end
    end

    logger.debug { "Removed #{removed} users from integrity security group" }

    # add the users that need to be in the group
    added = 0
    added_errors = 0

    new_users.each do |user|
      username = user.username
      user_email = user.email

      begin
        # check if the user exists (find by email and username)
        users = integriti.user_id_lookup(username).get.as_a.map(&.as_s)
        if users.empty?
          users = integriti.user_id_lookup(user_email).get.as_a.map(&.as_s) unless user_email == username
          if users.empty?
            new_user_id = integriti.create_user(user.name, username, user.phone).get.as_s
            users << new_user_id
            email_to_user_id[username] = new_user_id
          else
            # we want to update the users email address to be the username
            logger.debug { "updating user email #{user_email} to #{username}" }
            integriti.update_user_custom(users.first, username)
          end
        end

        # add the user permission group
        user_id = users.first
        integriti.modify_user_permissions(
          user_id: user_id,
          group_id: integriti_security_group,
          add: true,
          externally_managed: true
        )

        added += 1
      rescue error
        added_errors += 1
        logger.warn(exception: error) { "failed to add group #{user_group_id} to #{user_email}" }
      end
    end

    logger.debug { "Added #{added} users to integrity security group" }

    # CSV array
    csv_changed = sync_csv_field(ad_emails, email_to_user_id)

    result = {
      removed:        removed,
      removed_errors: removed_errors,
      added:          added,
      added_errors:   added_errors,
      base_building:  csv_changed,
    }
    logger.info { "integriti user sync results: #{result}" }
    result
  end

  # ===================
  # Group subscriptions
  # ===================

  # Create, update or delete of a member has occured
  # TODO:: use delta links in the future so we don't have to parse the whole group membership
  # https://learn.microsoft.com/en-us/graph/api/group-delta?view=graph-rest-1.0&tabs=http
  protected def subscription_on_crud(notification : NotifyEvent) : Nil
    subscription_on_missed
  end

  # Graph API failed to send us a notification or two
  protected def subscription_on_missed : Nil
    if !@syncing
      # very simple debounce as we seem to get 2 notifications for each update
      @sync_mutex.synchronize do
        return if @sync_requests > 0
        @sync_requests += 1
      end
      sleep 1
    else
      @sync_requests += 1
    end
    perform_user_sync
  end

  protected def subscription_resource(service_name : ServiceName) : String
    case service_name
    in .office365?
      "/groups/#{graph_group_id}/members"
    in .google?, Nil
      raise "google is not supported"
    end
  end

  # ===================
  # CSV Mappings
  # ===================

  DEFAULT_KEY = "default"

  getter building_id : String { get_building_id.not_nil! }

  def get_building_id
    building_setting = setting?(String, :building_zone_override)
    return building_setting if building_setting.presence
    zone_ids = staff_api.zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  protected def sync_csv_field(ad_emails : Array(String), email_to_user_id : Hash(String, String))
    mappings = csv_sync_mappings
    return "no CSV mappings" unless mappings && !mappings.empty?

    check = mappings.keys
    check.delete(DEFAULT_KEY)

    possible_csv_strings = mappings.values.flat_map do |hash|
      hash.values
    end

    logger.debug { "checking base building access for #{ad_emails.size} users" }

    now = Time.local(@time_zone).at_beginning_of_day
    end_of_day = 3.days.from_now.in(@time_zone).at_end_of_day
    building = building_id
    licence_users = building_parking_users

    ad_emails.each do |email|
      user_id = email_to_user_id[email]?
      if user_id.nil?
        logger.warn { "unable to apply CSV sync to #{email}. Possibly no matching integriti user" }
        next
      end

      # TODO:: lookup gender
      gender = DEFAULT_KEY

      # check if the user has any of the required bookings
      bookings = check.flat_map do |booking_type|
        staff_api.query_bookings(now.to_unix, end_of_day.to_unix, zones: {building}, type: booking_type, email: email).get.as_a
      end

      key = if booking = bookings.first?
              booking["booking_type"].as_s
            else
              DEFAULT_KEY
            end

      # attempt to find a number plate for this user
      if book = bookings.find { |booking| booking["extension_data"]["plate_number"].as_s rescue nil }
        number_plate = normalize_number_plate(book["extension_data"]["plate_number"].as_s, licence_users[email]?)
      else
        number_plate = licence_users[email]?
      end

      # TODO:: remove once we know how to handle multiple number plates
      number_plate = number_plate.split(',').first if number_plate

      # ensure appropriate security group is selected
      csv_security_group = mappings[key][gender]
      user = integriti.user(user_id).get
      csv_string = user["cf_csv"].as_s?
      license_string = user["cf_license"].as_s?

      update_csv = false
      update_license = number_plate.presence && number_plate != license_string

      if csv_string != csv_security_group
        if !csv_string.presence || csv_string.in?(possible_csv_strings)
          # change the CSV string of this user
          update_csv = true
        else
          logger.debug { "skipping csv update for #{email} as current mapping #{csv_string} may have been manually configured" }
        end
      end

      if update_csv && update_license
        integriti.update_user_custom(user_id, email: email, csv: csv_security_group, license: number_plate)
      elsif update_csv
        integriti.update_user_custom(user_id, email: email, csv: csv_security_group)
      else
        update_license
        integriti.update_user_custom(user_id, email: email, license: number_plate)
      end
    rescue error
      logger.warn(exception: error) { "failed to check csv field for #{email}" }
    end
  end
end
