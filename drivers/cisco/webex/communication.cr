require "placeos-driver"
require "placeos-driver/interface/chat_bot"
require "http"

require "./models/**"

module Cisco
  module Webex
    class Communication < PlaceOS::Driver
      include Interface::ChatBot

      descriptive_name "Cisco Webex Bot Communication"
      generic_name :Communication
      uri_base "wss://webex.placeos.com/ws/messages"

      default_settings({
        organization_id: "",
        api_key:         "",
      })

      protected getter! socket : HTTP::WebSocket

      def on_load
        on_update
      end

      def on_update
        headers = HTTP::Headers.new

        organization_id = setting(String, :organization_id)

        headers.merge!({"Organization-ID" => organization_id})
        headers.merge!({"X-API-Key" => setting(String, :api_key)})

        @socket = HTTP::WebSocket.new(URI.parse(config.uri.not_nil!.to_s), headers)

        spawn do
          socket.try(&.on_message do |message|
            event = Models::Event.from_json(JSON.parse(message).as_h.["event"].to_json)
            event_message = Models::Message.from_json(JSON.parse(message).as_h.["message"].to_json)

            id = Interface::ChatBot::Id.new(event_message.id.to_s, event_message.room_id.to_s, event.data.activity.actor.id, event.data.activity.actor.organization_id)
            bot_message = Interface::ChatBot::Message.new(id, event_message.text.to_s)

            publish("chat/webex/#{organization_id}/message", bot_message.to_json)
          end)

          socket.try(&.run)
        end
      end

      def notify_typing(id : Interface::ChatBot::Id)
      end

      def reply(id : Interface::ChatBot::Id, response : String, url : String? = nil, attachment : Interface::ChatBot::Attachment? = nil)
        files = [url.to_s] if url
        socket.try(&.send({"roomId" => id.room_id.to_s, "text" => response, "files" => files || [] of String}.to_json))
      end
    end
  end
end
