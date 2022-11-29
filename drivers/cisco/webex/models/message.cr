module Cisco
  module Webex
    module Models
      class Message
        include JSON::Serializable

        # The unique identifier for the message.
        @[JSON::Field(key: "id")]
        property id : String?

        # The unique identifier for the parent message.
        @[JSON::Field(key: "parentId")]
        property parent_id : String?

        # The room ID of the message.
        @[JSON::Field(key: "roomId")]
        property room_id : String?

        # The type of room.
        @[JSON::Field(key: "roomType")]
        property room_type : String?

        # The person ID of the recipient when sending a 1:1 message.
        @[JSON::Field(key: "toPersonId")]
        property to_person_id : String?

        # The email address of the recipient when sending a 1:1 message.
        @[JSON::Field(key: "toPersonEmail")]
        property to_person_email : String?

        # The message, in plain text.
        @[JSON::Field(key: "text")]
        property text : String?

        # The message, in Markdown format.
        @[JSON::Field(key: "markdown")]
        property markdown : String?

        # The text content of the message, in HTML format. This read-only property is used by the Webex Teams clients.
        @[JSON::Field(key: "html")]
        property html : String?

        # Public URLs for files attached to the message.
        @[JSON::Field(key: "files")]
        property files : Array(String)?

        # The person ID of the message author.
        @[JSON::Field(key: "personId")]
        property person_id : String?

        # The email address of the message author.
        @[JSON::Field(key: "personEmail")]
        property person_email : String?

        # People IDs for anyone mentioned in the message.
        @[JSON::Field(key: "mentionedPeople")]
        property mentioned_people : Array(String)?

        # Group names for the groups mentioned in the message.
        @[JSON::Field(key: "mentionedGroups")]
        property mentioned_groups : Array(String)?

        # Message content attachments attached to the message.
        # @[JSON::Field(key: "attachments")]
        # property attachments : Array(Attachment)?

        # The date and time the message was created.
        @[JSON::Field(key: "created")]
        property created : String?

        # The date and time the message was created.
        @[JSON::Field(key: "updated")]
        property updated : String?
      end
    end
  end
end
