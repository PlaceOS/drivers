require "json"
require "openssl/hmac"
require "placeos-driver/interface/door_security"

module Rhombus
  class Subscription
    include JSON::Serializable

    getter webhook : String
    getter secret : String?

    def initialize(@webhook, @secret = nil)
    end
  end

  class Webhook
    include JSON::Serializable

    getter door_id : String
    getter timestamp : Time
    getter signature : String? = nil
    getter action : PlaceOS::Driver::Interface::DoorSecurity::Action
    getter card_id : String?
    getter user_name : String?
    getter user_email : String?

    def initialize(event : PlaceOS::Driver::Interface::DoorSecurity::DoorEvent)
      @action = event.action
      @door_id = event.door_id
      @timestamp = Time.unix event.timestamp

      @card_id = event.card_id
      @user_name = event.user_name
      @user_email = event.user_email
    end

    def sign(secret : String?)
      if key = secret.presence
        @signature = OpenSSL::HMAC.hexdigest(:sha256, key, timestamp.to_rfc3339)
      else
        @signature = nil
      end
      self
    end
  end
end
