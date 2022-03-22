module Cisco
  module Webex
    module Commands
      class Greeting < Command
        def keywords : Array(String)
          ["hello", "hi"]
        end

        def description : String
          "This command simply responds to hello, hi, how are you, etc."
        end

        def execute(_event, _keyword, message)
          {"id" => message.room_id, "text" => "👋"}
        end
      end
    end
  end
end
