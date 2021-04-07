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
    transport = PlaceOS::HTTPClient.new self
    app_id = setting String, :application_id
    OpenAccess::Client.new transport, app_id
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
    logger.debug { "creating badge badge for cardholder #{personid}" }
    client.create Badge, **args
  end

  # Deletes a badge with the specified *badgekey*.
  @[Security(Level::Administrator)]
  def delete_badge(badgekey : Int32) : Nil
    logger.debug { "deleting badge #{badgekey}" }
    client.delete Badge, **args
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

  # Creates a new cardholder.
  #
  # An error will be returned if an existing cardholder exists for the specified
  # *email* address.
  @[Security(Level::Support)]
  def create_cardholder(
    email : String,
    firstname : String,
    lastname : String,
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
end


################################################################################
#
# Warning: nasty hacks below. These are intended as a _temporary_ measure to
# modify the behaviour of the driver framework as a POC.
#
# The intent is to provide a `HTTP::Client`-ish object that uses the underlying
# queue and config. This provides a familiar interface for users, but
# importantly also allows it to be passed as a compatible object to client libs
# that may already exist for the service being integrated.
#

abstract class PlaceOS::Driver::Transport
  def before_request(&callback : HTTP::Request ->)
    before_request = @before_request ||= [] of (HTTP::Request ->)
    before_request << callback
  end

  private def install_middleware(client : HTTP::Client)
    client.before_request do |req|
      @before_request.try &.each &.call(req)
    end
  end
end

class PlaceOS::Driver::TransportTCP
  def new_http_client(uri, context)
    previous_def.tap &->install_middleware(HTTP::Client)
  end
end

class PlaceOS::Driver::TransportHTTP
  def new_http_client(uri, context)
    previous_def.tap &->install_middleware(HTTP::Client)
  end
end

class PlaceOS::HTTPClient < HTTP::Client
  def initialize(@driver : PlaceOS::Driver)
    @host = ""
    @port = -1
  end

  delegate get, post, put, patch, delete, to: @driver

  def before_request(&block : HTTP::Request ->)
    @driver.transport.before_request &block
  end
end

# Patch in support for `body` in DELETE requests
class PlaceOS::Driver
  protected def delete(path, body : ::HTTP::Client::BodyType = nil,
                       params : Hash(String, String?) = {} of String => String?,
                       headers : Hash(String, String) | HTTP::Headers = HTTP::Headers.new,
                       secure = false, concurrent = false)
    transport.http("DELETE", path, body, params, headers, secure, concurrent)
  end
end
