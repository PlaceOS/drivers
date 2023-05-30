module Cisco
  module Webex
    module Api
      class Messages
        def initialize(@session : Session)
        end

        def list(room_id : String, parent_id : String = "", mentioned_people : String = "", before : String = "", before_message : String = "", max : Int32 = 50) : Array(Models::Message)
          params = Utils.hash_from_items_with_values(roomId: room_id, parentId: parent_id, mentionedPeople: mentioned_people, before: before, beforeMessage: before_message, max: max)
          response = @session.get([Constants::MESSAGES_ENDPOINT, "/"].join(""), params: params)
          data = JSON.parse(response.body)

          data.["items"].as_a.map do |item|
            Models::Message.from_json(item.to_json)
          end
        end

        def list_direct(person_id : String = "", person_email : String = "", parent_id : String = "") : Array(Models::Message)
          params = Utils.hash_from_items_with_values(personId: person_id, personEmail: person_email, parentId: parent_id)
          response = @session.get([Constants::MESSAGES_ENDPOINT, "/"].join(""), params: params)
          data = JSON.parse(response.body)

          data.["items"].as_a.map do |item|
            Models::Message.from_json(item.to_json)
          end
        end

        def create(room_id : String = "", parent_id : String = "", to_person_id : String = "", to_person_email : String = "", text : String = "", markdown : String = "") : Models::Message
          json = Utils.hash_from_items_with_values(roomId: room_id, parentId: parent_id, toPersonId: to_person_id, toPersonEmail: to_person_email, text: text, markdown: markdown)
          response = @session.post([Constants::MESSAGES_ENDPOINT, "/"].join(""), json: json)
          Models::Message.from_json(response.body)
        end

        def get(message_id : String) : Models::Message
          response = @session.get([Constants::MESSAGES_ENDPOINT, "/", message_id].join(""))
          Models::Message.from_json(response.body)
        end
      end
    end
  end
end
