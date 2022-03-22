module Cisco
  module Webex
    module Commands
      class Echo < Command
        def keywords : Array(String)
          ["echo"]
        end

        def description : String
          "This command simply replies your message!"
        end

        def execute(_event, _keyword, message)
          {"id" => message.room_id, "text" => message.text}
        end
      end
    end
  end
end
