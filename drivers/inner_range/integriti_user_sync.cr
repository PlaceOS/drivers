require "placeos-driver"
require "place_calendar"
require "xml"

require "../place/models/workplace_subscriptions"

class InnerRange::IntegritiUserSync < PlaceOS::Driver
  include Place::WorkplaceSubscription

  descriptive_name "Integriti User Sync"
  generic_name :IntegritiUserSync

  default_settings({
    user_group_id:            "building@org.com",
    sync_cron:                "0 21 * * *",
    integriti_security_group: "",

    # use these for enabling push notifications
    # push_authority: "authority-GAdySsf05mL"
    # push_notification_url: "https://placeos-dev.aca.im/api/engine/v2/notifications/office365"
  })

  accessor directory : Calendar_1
  accessor integriti : Integriti_1

  @time_zone : Time::Location = Time::Location.load("GMT")

  @syncing : Bool = false
  @sync_mutex : Mutex = Mutex.new
  @sync_requests : Int32 = 0

  def on_load
    on_update
  end

  def on_update
    @time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(@time_zone_string)

    @sync_cron = setting?(String, :sync_cron).presence || "0 21 * * *"
    @user_group_id = setting(String, :user_group_id)
    @integriti_security_group = setting(String, :integriti_security_group)

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

  class PlaceCalendar::Member
    property next_page : String? = nil
  end

  alias DirUser = PlaceCalendar::Member

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

    ad_emails = [] of String
    new_users = [] of DirUser

    # get the list of users in the active directory (page by page)
    users = Array(DirUser).from_json directory.get_members(user_group_id).get.to_json
    loop do
      # keep track of users that need to be created
      users.each do |user|
        user_email = user.email.downcase
        unless user.suspended
          ad_emails << user_email
          new_users << user unless email_to_user_id[user_email]?
        end
      end

      next_page = users.first?.try(&.next_page)
      break unless next_page

      # ensure we don't blow any request limits
      logger.debug { "fetching next page..." }
      sleep 1
      users = Array(DirUser).from_json directory.get_members(user_group_id, next_page).get.to_json
    end

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

    # add the users that need to be in the group
    added = 0
    added_errors = 0

    new_users.each do |user|
      user_email = user.email.downcase
      begin
        # check if the user exists (find by email)
        users = integriti.user_id_lookup(user_email).get.as_a.map(&.as_s)
        if users.empty?
          users << integriti.create_user(user.name, user_email, user.phone).get.as_s
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

    result = {
      removed:        removed,
      removed_errors: removed_errors,
      added:          added,
      added_errors:   added_errors,
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
  def subscription_on_crud(notification : NotifyEvent) : Nil
    @sync_requests += 1
    perform_user_sync
  end

  # Graph API failed to send us a notification or two, we can ignore this as nightly sync's will catch it
  def subscription_on_missed : Nil
  end

  def subscription_resource(service_name : ServiceName) : String
    case service_name
    in .office365?
      "/groups/#{graph_group_id}/members"
    in .google?, Nil
      raise "google is not supported"
    end
  end
end
