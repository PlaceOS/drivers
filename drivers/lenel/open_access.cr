require "placeos-driver"
require "time"

class Lenel::OpenAccess < PlaceOS::Driver; end

require "./open_access/client"

class Lenel::OpenAccess < PlaceOS::Driver
  include OpenAccess::Models

  generic_name :Security
  descriptive_name "Lenel OpenAccess"
  description "Bindings for Lenel OnGuard physical security system"
  uri_base "https://example.com/api/access/onguard/openaccess"
  default_settings({
    application_id: "",
    directory_id:   "",
    username:       "",
    password:       "",
  })

  private getter client : OpenAccess::Client do
    app_id = setting String, :application_id
    OpenAccess::Client.new transport_wrapper, app_id
  end

  private getter transport_wrapper : PlaceOS::HTTPClient do
    wrapper = PlaceOS::HTTPClient.new self
    transport.before_request do |request|
      wrapper.before_lenel_request.try &.each &.call(request)
    end
    wrapper
  end

  def on_load
    schedule.every 5.minutes, &->check_comms
  end

  def on_update
    logger.debug { "settings updated" }
    client.app_id = setting String, :application_id
    authenticate!
  end

  def connected
    logger.debug { "connected" }
    authenticate! if client.token.nil?
  end

  def disconnected
    logger.debug { "disconnected" }
    client.token = nil
  end

  private def authenticate! : Nil
    username = setting String, :username
    password = setting String, :password
    directory = setting?(String, :directory_id).presence

    logger.debug { "requesting access token for #{username}" }

    begin
      auth = client.login username, password, directory
      client.token = auth[:session_token]

      renewal_time = auth[:token_expiration_time] - 5.minutes
      schedule.at renewal_time, &->authenticate!

      logger.info { "authenticated - renews at #{renewal_time}" }

      set_connected_state true
    rescue e
      logger.error { "authentication failed: #{e.message}" }
      set_connected_state false
    end
  end

  # Test service connectivity.
  @[Security(Level::Support)]
  def check_comms
    logger.debug { "checking service connectivity" }
    if client.token
      client.keepalive
      logger.info { "client online and authenticated" }
    else
      client.version
      logger.warn { "service reachable, no active auth session" }
      authenticate!
    end
  rescue e : OpenAccess::Error
    logger.error { e.message }
    set_connected_state false
  end

  # Query the directories available for auth.
  @[Security(Level::Support)]
  def list_directories
    client.directories
  end

  # Gets the version of the attached OnGuard system.
  @[Security(Level::Support)]
  def version
    client.version
  end

  # Query the available badge types.
  #
  # Badge types contain default configuration that is applied to any badge
  # created under them. This includes items such as access areas, activation
  # windows and other bulk config. These may then be override on individual
  # badge instances.
  @[Security(Level::Support)]
  def badge_types
    client.lookup BadgeType
  end

  # List badges belonging to a cardholder
  @[Security(Level::Support)]
  def list_badges(personid : Int32)
    client.lookup Badge, filter: %(personid = #{personid})
  end

  # Get badge by badgekey (instead of id)
  # Note: id is the number in the QR data or burnt to the swipe card. badgekey is Lenel's primary key for badges
  @[Security(Level::Support)]
  def lookup_badge_key(badgekey : Int32)
    badges = client.lookup Badge, filter: %(badgekey = #{badgekey})
    if badges.size > 1
      logger.warn { "duplicate records exist for #{badgekey}" }
    end
    badges.first?
  end

  # Get badge by id (instead of badgekey)
  @[Security(Level::Support)]
  def lookup_badge_id(id : Int64)
    badges = client.lookup Badge, filter: %(id = #{id})
    if badges.size > 1
      logger.warn { "duplicate records exist for #{id}" }
    end
    badges.first?
  end

  # Creates a new badge of the specied *type*, belonging to *personid* with a
  # specific *id*.
  #
  # Note: 'id' is the physical badge number (e.g. the ID written to an NFC chip)
  @[Security(Level::Administrator)]
  def create_badge(
    type : Int32,
    id : Int64,
    personid : Int32,
    uselimit : Int32? = nil,
    activate : Time? = nil,
    deactivate : Time? = nil
  )
    logger.debug { "creating badge for cardholder #{personid}" }
    client.create Badge, **args
  end

  def create_badge_epoch(
    type : Int32,
    id : Int64,
    personid : Int32,
    activate_epoch : Int32,
    deactivate_epoch : Int32,
    uselimit : Int32? = nil
  )
    activate = Time.unix(activate_epoch)
    deactivate = Time.unix(deactivate_epoch)

    create_badge(
      type: type,
      id: id,
      personid: personid,
      activate: activate,
      deactivate: deactivate,
      uselimit: uselimit
    )
  end

  @[Security(Level::Administrator)]
  def update_badge(
    badgekey : Int32,
    id : Int64? = nil,
    uselimit : Int32? = nil,
    activate : Time? = nil,
    deactivate : Time? = nil
  )
    logger.debug { "Updating badge #{badgekey}" }
    client.update Badge, **args
  end

  @[Security(Level::Administrator)]
  def update_badge_epoch(
    badgekey : Int32,
    activate_epoch : Int32,
    deactivate_epoch : Int32,
    id : Int64? = nil,
    uselimit : Int32? = nil
  )
    activate = Time.unix(activate_epoch)
    deactivate = Time.unix(deactivate_epoch)

    update_badge(
      badgekey: badgekey,
      id: id,
      activate: activate,
      deactivate: deactivate,
      uselimit: uselimit
    )
  end

  # Deletes a badge with the specified *badgekey*.
  @[Security(Level::Administrator)]
  def delete_badge(badgekey : Int32) : Nil
    logger.debug { "deleting badge #{badgekey}" }
    client.delete Badge, **args
  end

  def delete_badges(badgekeys : Array(Int32)) : Int32
    badgekeys.count do |badge_key|
      begin
        delete_badge(badge_key)
        1
      rescue OpenAccess::Error
        logger.debug { "failed to delete badge #{badge_key}" }
        0
      end
    end
  end

  # Lookup a cardholder by *email* address.
  @[Security(Level::Support)]
  def lookup_cardholder(email : String)
    cardholders = client.lookup Cardholder, filter: %(email = "#{email}")
    if cardholders.size > 1
      logger.warn { "duplicate records exist for #{email}" }
    end
    cardholders.first?
  end

  # Lookup a cardholder by ID
  @[Security(Level::Support)]
  def lookup_cardholder_id(id : Int32)
    cardholders = client.lookup Cardholder, filter: %(id = #{id})
    if cardholders.size > 1
      logger.warn { "duplicate records exist for #{id}" }
    end
    cardholders.first?
  end

  # Creates a new cardholder.
  #
  # An error will be returned if an existing cardholder exists for the specified
  # *email* address.
  @[Security(Level::Support)]
  def create_cardholder(
    email : String,
    firstname : String,
    lastname : String
  )
    logger.debug { "creating cardholder record for #{email}" }
    unless client.count(Cardholder, filter: %(email = "#{email}")).zero?
      raise ArgumentError.new "record already exists for #{email}"
    end
    client.create Cardholder, **args
  end

  # Deletes a cardholed by their person *id*.
  @[Security(Level::Administrator)]
  def delete_cardholder(id : Int32) : Nil
    logger.debug { "deleting cardholder #{id}" }
    client.delete Cardholder, **args
  end

  # List Logged Events
  @[Security(Level::Support)]
  def list_events(filter : String)
    client.get_logged_events filter
  end

  # List events that occured during a given time window. Default to past 24h.
  def list_events_in_range(
    filter : String,
    from : Time? = nil,
    til : Time? = nil
  )
    til ||= Time.local
    from ||= til - 1.day
    client.get_logged_events(filter + %( AND timestamp >= #{from.to_s} AND timestamp <= #{til.to_s}))
  end
end

################################################################################
# The intent below is to provide a `HTTP::Client`-ish object that uses the
# underlying queue and config. This provides a familiar interface for users, but
# importantly also allows it to be passed as a compatible object to client libs
# that may already exist for the service being integrated.
#

class PlaceOS::HTTPClient < HTTP::Client
  def initialize(@driver : PlaceOS::Driver)
    @host = ""
    @port = -1
  end

  delegate get, post, put, patch, delete, to: @driver

  getter before_lenel_request : Array(HTTP::Request ->) = [] of (HTTP::Request ->)

  def before_request(&callback : HTTP::Request ->)
    @before_lenel_request << callback
  end
end
