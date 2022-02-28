module Cisco
  module Webex
    class Client
      Log = ::Log.for(self)

      property id : String
      property keywords : Hash(String, Command)
      property socket : HTTP::WebSocket?

      def initialize(@name : String, @access_token : String, @emails : String, @session : Session, @commands : Array(Command))
        @rooms = Api::Rooms.new(@session)
        @people = Api::People.new(@session)
        @messages = Api::Messages.new(@session)

        @keywords =
          @commands
            .map { |command| command.keywords.map { |keyword| {"#{keyword}" => command} } }
            .flatten
            .reduce { |acc, i| acc.try(&.merge(i.not_nil!)) }

        @id = @people.me.id
      end

      def rooms
        @rooms
      end

      def people
        @people
      end

      def messages
        @messages
      end

      private def device(check_existing : Bool = true) : Models::Device
        if check_existing
          response = @session.get([Constants::DEFAULT_DEVICE_URL, "/", "devices"].join(""))
          data = JSON.parse(response.body)

          devices = data.["devices"].as_a.map do |item|
            Models::Device.from_json(item.to_json)
          end

          devices.each do |device|
            if device.name == nil
              next
            end

            if device.name == Constants::DEVICE["name"]
              return device
            end
          end
        end

        response = @session.post([Constants::DEFAULT_DEVICE_URL, "/", "devices"].join(""), json: Constants::DEVICE)
        Models::Device.from_json(response.body)
      end

      private def message_id(activity) : String
        # In order to geo-locate the correct DC to fetch the message from, you need to use the base64 Id of the message.
        id = activity.id
        target_url = activity.target.url
        target_id = activity.target.id

        verb = activity.verb == "post" ? "messages" : "attachment/actions"

        message_url = target_url.gsub(["conversations", "/", target_id].join(""), [verb, "/", id].join(""))
        response = Halite.get(message_url, headers: {"Authorization" => ["Bearer", @access_token].join(" ")})

        message = JSON.parse(response.body)
        message["id"].to_s
      end

      private def process_incoming_websocket_message(socket, message)
        peek = Models::Peek.from_json(message)
        return if peek.data.event_type == "status.start_typing"

        begin
          event = Models::Event.from_json(message)

          if event.data.event_type == "conversation.activity"
            activity = event.data.activity
            Log.debug { "Activity verb is: #{activity.verb}" }

            if activity.verb == "post"
              id = message_id(activity)
              message = self.messages.get(id)

              if message.person_id != @id
                # Ack that this message has been processed. This will prevent the message coming again.
                socket.send({"type" => "ack", "messageId": id}.to_json)

                if message.text.starts_with?(@name)
                  message.text = message.text.sub(@name, "").strip
                end

                return if @emails.none?(activity.actor.email)

                keyword = message.text.split.first.downcase

                if @keywords[keyword]?
                  message.text = message.text.sub(keyword, "").strip
                  message = @keywords[keyword].execute(event, keyword, message)

                  room_id = message["id"]? || ""
                  parent_id = message["parent_id"]? || ""
                  to_person_id = message["to_person_id"]? || ""
                  to_person_email = message["to_person_email"]? || ""
                  text = message["text"]? || ""
                  markdown = message["markdown"]? || ""

                  self.messages.create(room_id, parent_id, to_person_id, to_person_email, text, markdown)
                else
                end
              end
            else
            end
          end
        rescue e : Exception
          Log.debug(exception: e) { }
        end
      end

      def run : Void
        device = device()
        @socket = HTTP::WebSocket.new(URI.parse(device.websocket_url))

        @socket.try(&.on_open do
          message = {
            "id"         => UUID.random.to_s,
            "type"       => "authorization",
            "trackingId" => ["webex", "-", UUID.random.to_s].join(""),
            "data"       => {
              "token" => ["Bearer", @access_token].join(" "),
            },
          }

          @socket.try(&.send(message.to_json))
        end)

        @socket.try(&.on_message do |message|
          process_incoming_websocket_message(@socket.not_nil!, message)
        end)

        @socket.try(&.on_binary do |binary|
          process_incoming_websocket_message(@socket.not_nil!, String.new(binary))
        end)

        @socket.try(&.run)
      end

      def stop : Void
        @socket.close
      end
    end
  end
end
