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
    transport.before_request do |req|
      logger.debug { req.inspect }
    end
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
      auth = client.add_authentication username, password, directory
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
      client.get_keepalive
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
    client.get_directories
  end

  # Perform an arbitrary get query.
  # FIXME: tempory for system debugging
  @[Security(Level::Administrator)]
  def __raw_get(resource : String)
    client.__raw_get resource
  end

  # Gets the version of the attached OnGuard system.
  def version
    client.version
  end

  @[Security(Level::Support)]
  def badge_types
    client.get_instances Lnl_BadgeType
  end

  @[Security(Level::Administrator)]
  def create_badge(
    type : Int32,
    personid : Int32,
    uselimit : Int32? = nil,
    activate : Time? = nil,
    deactivate : Time? = nil
  ) : Lnl_Badge
    logger.debug { "creating badge badge for cardholder id #{personid}" }
    client.add_instance Lnl_Badge, **args
  end

  @[Security(Level::Administrator)]
  def delete_badge(id : Int32) : Nil
    logger.debug { "deleting badge #{id}" }
    client.delete_instance Lnl_Badge, id: id
  end

  def lookup_visitor(email : String) : Lnl_Visitor?
    visitors = client.get_instances Lnl_Visitor, filter: %(email = "#{email}")
    logger.warn { "duplicate visitor records exist for #{email}" } if visitors.size > 1
    visitors.first?
  end

  @[Security(Level::Support)]
  def create_visitor(
    email : String,
    firstname : String,
    lastname : String,
    organization : String? = nil,
    title : String? = nil,
  ) : Lnl_Visitor
    logger.debug { "creating visitor record for #{email}" }

    unless client.get_count(Lnl_Visitor, filter: %(email = "#{email}")).zero?
      raise ArgumentError.new "visitor record already exists for #{email}"
    end

    client.add_instance Lnl_Visitor, **args
  end

  @[Security(Level::Administrator)]
  def delete_visitor(id : Int32) : Nil
    logger.debug { "deleting visitor #{id}" }
    client.delete_instance Lnl_Visitor, id: id
  end


  def lookup_card_holder(email : String) : Lnl_CardHolder?
    cardholders = client.get_instances Lnl_CardHolder, filter: %(email = "#{email}")
    logger.warn { "duplicate records exist for #{email}" } if cardholders.size > 1
    cardholders.first?
  end

  @[Security(Level::Support)]
  def create_card_holder(
    email : String,
    firstname : String,
    lastname : String,
  ) : Lnl_CardHolder
    logger.debug { "creating cardholder record for #{email}" }

    unless client.get_count(Lnl_CardHolder, filter: %(email = "#{email}")).zero?
      raise ArgumentError.new "record already exists for #{email}"
    end

    client.add_instance Lnl_CardHolder, **args
  end

  @[Security(Level::Administrator)]
  def delete_card_holder(id : Int32) : Nil
    logger.debug { "deleting cardholder #{id}" }
    client.delete_instance Lnl_CardHolder, id: id
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
