module Cisco
  module Webex
    module Models
      class Room
        include JSON::Serializable

        # A unique identifier for the room.
        @[JSON::Field(key: "id")]
        property id : String

        # The name of the room.
        @[JSON::Field(key: "title")]
        property title : String

        # The room type.
        @[JSON::Field(key: "type")]
        property type : String

        # Whether the room is moderated (locked) or not.
        @[JSON::Field(key: "isLocked")]
        property is_locked : Bool

        # The ID for the team with which this room is associated..
        @[JSON::Field(key: "teamId")]
        property team_id : String?

        # The date and time of the room"s last activity..
        @[JSON::Field(key: "lastActivity")]
        property last_activity : String

        # The ID of the person who created this room.
        @[JSON::Field(key: "creatorId")]
        property creator_id : String

        # The date and time the room was created.
        @[JSON::Field(key: "created")]
        property created : String

        # The ID of the organization which owns this room.
        @[JSON::Field(key: "ownerId")]
        property owner_id : String
      end
    end
  end
end
