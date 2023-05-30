require "json"

module Pattr
  abstract class Request
    include JSON::Serializable

    # request type hint
    use_json_discriminator "request", {
      "location" => Location,
    }

    getter user : String
  end

  class Location < Request
    getter request : String = "location"

    # user emails / usernames of users we want to locate
    getter referencing : Array(String)
  end

  class PlaceLocationResult
    include JSON::Serializable

    # wireless, desk, meeting, booking
    getter location : String

    # zone ids
    getter building : String
    getter level : String

    # system id (if it's a meeting room)
    getter sys_id : String?
  end
end
