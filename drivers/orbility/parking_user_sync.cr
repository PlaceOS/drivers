require "placeos-driver"
require "place_calendar"
require "set"

require "./parking_rest_api_models"
require "../place/models/workplace_subscriptions"

class Orbility::ParkingUserSync < PlaceOS::Driver
  include Place::WorkplaceSubscription

  descriptive_name "Orbility User Sync"
  generic_name :OrbilityUserSync
  description %(Grabs users from active directory, looks up swipe card numbers from gallagher and syncs these to orbility)

  default_settings({
    # Azure user group we want to sync
    user_group_id: "building@org.com",

    # The user model ext that contains car license plate numbers
    # returned as unmapped.car_license_ext on the user models
    car_license_ext: "extension_8418f8b70257442aa5e75af8f2ff38a3_carLicense",
    sync_cron:       "0 21 * * *",

    # create subscription => create card (use subscription id)
    orbility_product_id:  6,
    orbility_contract_id: 6,

    # dda offer 1
    # students offer 2
    # staff offer 3
    orbility_offer_id: 3,

    # use these for enabling push notifications
    _push_authority:        "authority-GAdySsf05mL",
    _push_notification_url: "https://placeos-dev.aca.im/api/engine/v2/notifications/office365",
  })

  # card_holder_id_lookup(user_email) => gallagher_id
  # get_cardholder(gallagher_id) => cards[].status == active => cards[].number
  accessor gallagher : Gallagher_1
  accessor directory : Calendar_1
  accessor staff_api : StaffAPI_1
  accessor orbility : Orbility_1

  @time_zone : Time::Location = Time::Location.load("GMT")

  @syncing : Bool = false
  @sync_mutex : Mutex = Mutex.new
  @sync_requests : Int32 = 0

  def on_update
    @time_zone_string = setting?(String, :time_zone).presence || config.control_system.not_nil!.timezone.presence || "GMT"
    @time_zone = Time::Location.load(@time_zone_string)

    @sync_cron = setting?(String, :sync_cron).presence || "0 21 * * *"
    @user_group_id = setting(String, :user_group_id)
    @car_license_ext = setting(String, :car_license_ext)

    @orbility_product_id = setting(Int64, :orbility_product_id)
    @orbility_contract_id = setting(Int64, :orbility_contract_id)
    @orbility_offer_id = setting(Int64, :orbility_offer_id)

    @graph_group_id = nil

    schedule.clear
    schedule.cron(@sync_cron, @time_zone) { perform_user_sync }

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
  getter! car_license_ext : String

  getter! orbility_product_id : Int64
  getter! orbility_contract_id : Int64
  getter! orbility_offer_id : Int64

  class ::PlaceCalendar::Member
    property next_page : String? = nil
  end

  alias DirUser = ::PlaceCalendar::Member

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

  @warnings : Array(String) = [] of String

  # Get existing parking card details
  protected def get_card_details : Hash(String, Card)
    subscriptions = Array(Subscription).from_json(orbility.subscriptions(orbility_contract_id).get.to_json)
    cards = subscriptions.compact_map do |sub|
      if card_id = sub.card_ids.first?
        Card.from_json(orbility.card(card_id).get.to_json)
      end
    end

    lookup = {} of String => Card
    cards.each do |card|
      person = card.person
      if id = person.unique_id || card.access_card_no || person.emails.first?.try(&.downcase)
        if existing = lookup[id]?
          @warnings << "duplicate card found #{card.id}: #{person.first_name} #{person.name} #{person.emails}"
          next
        end
        lookup[id] = card
      else
        @warnings << "unknown owner for card #{card.id}: #{person.first_name} #{person.name} #{person.emails}"
      end
    end

    lookup
  end

  PLATES_DEFAULT = [] of String

  # extract users number plates from Azure
  protected def user_plates(user) : Array(String)
    license_plates = PLATES_DEFAULT
    if unmapped = user.unmapped
      license_plates = unmapped[car_license_ext]?.try(&.as_a.map(&.as_s)) || PLATES_DEFAULT
    end
    license_plates.reject! { |plate| plate.blank? || plate.size > 12 }
  end

  getter cached_security_ids : Hash(String, String | Int64) = {} of String => String | Int64

  # find the id for the user in the security system
  protected def lookup_security_id(username : String, email : String) : String | Int64 | Nil
    id = cached_security_ids[username]?
    return id if id

    # check username lookup
    json = (gallagher.card_holder_id_lookup(username).get rescue nil)
    if json && json.raw
      id = (String | Int64).from_json(json.to_json)
      cached_security_ids[username] = id
      return id
    end

    # handle the case where we have a json `null` response
    json = (gallagher.card_holder_id_lookup(email).get rescue nil)
    if json && json.raw
      cached_security_ids[username] = (String | Int64).from_json(json.to_json)
    end
  end

  # find users swipe card number in the security system
  protected def lookup_security_card(username : String, email : String) : String?
    security_id = lookup_security_id(username, email)
    if security_id.nil?
      @warnings << "no swipe card found for #{username} / #{email}"
      return nil
    end

    user_details = gallagher.get_cardholder(security_id).get
    if cards = user_details["cards"]?.try(&.as_a)
      cards.each do |card|
        if card["status"]["type"].as_s == "active"
          return card["number"].as_s
        end
      end
    end
  end

  protected def sync_users
    @warnings = [] of String

    # get the list of users in the parking system
    cards = get_card_details

    logger.debug { "Number of existing users in parking system: #{cards.size}" }

    dir_users = [] of String
    new_users = [] of DirUser
    update_users = [] of Tuple(DirUser, Card)

    # get the list of users in the active directory (page by page)
    users = Array(DirUser).from_json directory.get_members(user_group_id, additional_fields: {car_license_ext}).get.to_json
    loop do
      # keep track of users that need to be created
      users.each do |user|
        unless user.suspended
          email = user.email.strip.downcase
          user.email = email
          username = user.username.strip.downcase
          user.username = username

          # use the phone field to store the card number
          swipe_card_number = lookup_security_card(username, email)
          user.phone = swipe_card_number

          # check if the user is already in the parking system
          if swipe_card_number
            parking_card = cards[user.id]? || cards[swipe_card_number]? || cards[username]?
          else
            parking_card = cards[user.id]? || cards[username]?
          end

          # store the checked emails and users that we need to add to the parking system
          dir_users << user.id
          if parking_card
            if parking_card.access_card_no != swipe_card_number
              update_users << {user, parking_card}
            else
              parking_licences = Set.new(parking_card.licence_plates)
              storage_licenses = Set.new(user_plates(user))
              if parking_licences != storage_licenses
                update_users << {user, parking_card}
              end
            end
          else
            new_users << user
          end
        end
      end

      next_page = users.first?.try(&.next_page)
      break unless next_page

      # ensure we don't blow any request limits
      logger.debug { "fetching next page..." }
      sleep 500.milliseconds
      users = Array(DirUser).from_json directory.get_members(user_group_id, next_page, {car_license_ext}).get.to_json
    end

    logger.debug { "Number of users in Parking system: #{cards.size}" }
    logger.debug { "Number of users in Directory: #{dir_users.size}" }

    # find all the users that need to be removed from parking
    removed = 0
    removed_errors = 0

    remove_users = cards.keys - dir_users
    remove_users.each do |parking_card_id|
      card = cards[parking_card_id]
      begin
        orbility.delete_card(card.id).get
        orbility.delete_subscription(card.subscription_id).get
        removed += 1
      rescue error
        removed_errors += 1
        logger.warn(exception: error) { "failed to remove card #{card.id}: #{card.person.first_name} #{card.person.name} #{card.person.emails}" }
      end
    end

    logger.debug { "Removed #{removed} users from parking system" }

    # add the users that need to be in parking
    added = 0
    added_errors = 0

    start_date = 1.week.ago
    end_date = 30.years.from_now

    new_users.each do |user|
      username = user.username
      user_email = user.email
      swipe_card_number = user.phone
      first_name, last_name = user.name.as(String).split(" ", 2)

      begin
        # create a subscription
        sub = Subscription.new(orbility_product_id, orbility_contract_id, orbility_offer_id, start_date, end_date)
        json = (orbility.add_subscription(sub).get rescue nil)

        if json && json.raw
          sub_id = Int64?.from_json(json.to_json)
        end

        if sub_id.nil?
          added_errors += 1
          @warnings << "failed to create subscription for #{user_email}: #{swipe_card_number}"
          next
        end

        # create a card
        person = Person.new(first_name, last_name, user.id, [username, user_email].uniq!)
        card = CardUpdate.new(sub_id, swipe_card_number, user_plates(user), person)
        orbility.add_card(card).get

        added += 1
      rescue error
        added_errors += 1
        msg = "failed to create subscription for #{user_email}: #{swipe_card_number}"
        @warnings << msg
        logger.warn(exception: error) { msg }
      end
    end

    logger.debug { "Added #{added} users to parking system" }

    # Sync any that need updating
    updated = 0
    update_errors = 0
    update_users.each do |(user, card)|
      begin
        parking_card = CardUpdate.new(card.subscription_id, user.phone, user_plates(user), card.person, card.id)
        orbility.update_card(parking_card).get
        updated += 1
      rescue error
        update_errors += 1
        msg = "failed to update card for #{user.name} #{user.email}: #{user.phone}"
        @warnings << msg
        logger.warn(exception: error) { msg }
      end
    end

    result = {
      removed:        removed,
      removed_errors: removed_errors,
      added:          added,
      added_errors:   added_errors,
      updated:        updated,
      update_errors:  update_errors,
      warnings:       @warnings,
    }
    @last_result = result
    self[:last_result] = result
    @warnings = [] of String
    logger.info { "integriti user sync results: #{result}" }
    result
  end

  getter last_result : NamedTuple(
    removed: Int32,
    removed_errors: Int32,
    added: Int32,
    added_errors: Int32,
    updated: Int32,
    update_errors: Int32,
    warnings: Array(String),
  )? = nil

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
end
