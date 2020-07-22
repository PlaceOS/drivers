require "placeos-driver"
require "time"

class Lenel::OpenAccess < PlaceOS::Driver; end
require "./open_access/client"

class PlaceOS::DriverRequestProxy
  def initialize(@driver : PlaceOS::Driver); end
  delegate get, post, put, patch, delete, to: @driver
end

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

  private getter client : OpenAccess::Client(PlaceOS::DriverRequestProxy) do
    transport = PlaceOS::DriverRequestProxy.new self
    app_id = setting String, :application_id
    OpenAccess::Client.new transport, app_id
  end

  def on_load
    # Hearbeat for base service connectivity
    schedule.every 5.minutes, &->version
  end

  def on_update
    authenticate!
  end

  def connected
    authenticate! if client.token.nil?
  end

  def authenticate! : Nil
    username  = setting String, :username
    password  = setting String, :password
    directory = setting String, :directory_id

    begin
      auth = client.add_authentication username, password, directory
      client.token = auth[:session_token]

      renewal_time = auth[:token_expiration_time] - 5.minutes
      schedule.at renewal_time, &->authenticate!

      set_connected_state true
    rescue e
      client.token = nil
      set_connected_state false
      raise e
    end
  end

  # Gets the version of the attached OnGuard system.
  def version
    client.version
  end

  # TODO: remove me, temp for testing
  def get_test
    client.get_instances Lnl_AccessGroup
  end
end

