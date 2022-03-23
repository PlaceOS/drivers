module Cisco
  module Webex
    abstract class Command
      abstract def keywords : Array(String)
      abstract def description : String
      abstract def execute(event, keyword, message)
    end
  end
end
