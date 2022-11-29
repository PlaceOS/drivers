require "placeos-driver"
require "placeos-driver/interface/chat_bot"
require "placeos-driver/interface/locatable"
require "place_calendar"

module Cisco
  module Webex
    class Booking < PlaceOS::Driver
      default_settings({keyword: "book", organization_id: ""})

      def on_load
        on_update
      end

      def on_update
        organization_id = setting(String, :organization_id)
        monitor("chat/webex/#{organization_id}/message") { |_subscription, payload| on_message(payload) }
      end

      def on_message(message : String)
        message = Interface::ChatBot::Message.from_json(message)

        keyword = message.text.split.first.downcase
        text = message
          .text
          .sub(keyword, "")
          .sub("a room", "")
          .strip

        # Ignore the message if the keyword doesn't match the booking keyword specified in the settings
        if keyword != setting(String, :keyword)
          send_message(message.id, "Specified keyword is not recognized as a valid acommand for the PlaceOS Bot, #{keyword}.")
          send_message(message.id, "An example booking command would look something like this: #{setting(String, :keyword)} a room for 30 minutes")

          return
        end

        # Notify the user to await for a free room
        send_message(message.id, "Looking for an available room to book, please wait!")

        # Split the remaining text into chunks to process them
        conjunction, period, measurement = text.split

        case measurement
        when "hours"
          period_in_seconds = (period.to_i * 3600).to_i64
          event = PlaceCalendar::Event.from_json(system.implementing(Interface::Locatable).book_now(period_in_seconds).get.first.to_json)
          send_message(message.id, "Successfully booked an event #{event.title}, from #{event.event_start}, to #{event.event_end}, in #{event.timezone}, on #{event.host}.")
        when "minutes"
          period_in_seconds = (period.to_i * 60).to_i64
          event = PlaceCalendar::Event.from_json(system.implementing(Interface::Locatable).book_now(period_in_seconds).get.first.to_json)
          send_message(message.id, "Successfully booked an event #{event.title}, from #{event.event_start}, to #{event.event_end}, in #{event.timezone}, on #{event.host}.")
        when "seconds"
          event = PlaceCalendar::Event.from_json(system.implementing(Interface::Locatable).book_now(period.to_i64).get.first.to_json)
          send_message(message.id, "Successfully booked an event #{event.title}, from #{event.event_start}, to #{event.event_end}, in #{event.timezone}, on #{event.host}.")
        else
          send_message(message.id, "Specified measurement is not recognized as a valid measurement, please use: minutes, seconds or hours.")
        end
      end

      private def send_message(id : Interface::ChatBot::Id, response : String)
        system.implementing(Interface::ChatBot).reply(Interface::ChatBot::Message.new(id, response).to_json)
      end
    end
  end
end
