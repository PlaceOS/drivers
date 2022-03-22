require "placeos-driver"
require "halite"
require "log"
require "json"
require "uuid"
require "http"
require "./webex/**"

module Cisco
  module Webex
    class Bot < PlaceOS::Driver
      # Discovery Information
      descriptive_name "Cisco Webex Bot"
      generic_name :Webex

      default_settings({
        access_token: "The PlaceOS bot Webex access token",
        emails:       [] of String,
      })

      @access_token = setting(String, :access_token)
      @emails = setting(Array(String), :emails)

      @session = Session.new(access_token: setting(String, :access_token))

      @client = Client.new(
        name: "PlaceOS",
        access_token: @access_token,
        emails: @emails,
        session: @session,
        commands: [
          Commands::Greeting.new,
        ] of Command
      )

      def on_update
        @access_token = setting(String, :access_token)
        @emails = setting(Array(String), :emails)
      end

      def connected
        @client.run
      end

      def disconnected
        @client.stop
      end
    end
  end
end
