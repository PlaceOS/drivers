module Cisco
  module Webex
    module Api
      class People
        def initialize(@session : Session)
        end

        def me : Models::Person
          response = @session.get([Constants::PEOPLE_ENDPOINT, "/", "me"].join(""))
          Models::Person.from_json(response.body)
        end
      end
    end
  end
end
