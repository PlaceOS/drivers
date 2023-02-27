require "json"

module Place::Chat
  struct ConferenceDetails
    include JSON::Serializable

    getter place_id : String
    getter space_id : String
    getter host_pin : String
    getter guest_pin : String

    @[JSON::Field(ignore: true)]
    getter created_at : Time

    def initialize(@place_id, @space_id, @host_pin, @guest_pin)
      @created_at = Time.utc
    end
  end

  class Participant
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    property name : String
    property email : String?
    property phone : String?

    # the type of guest (additional information)
    property type : String?
    property text_chat_only : Bool? = false

    # the placeos user id we would like to notify if we have the user details
    property chat_to_user_id : String?

    # the users chat id. This purely generated on the frontend
    # not a placeos user_id, we use it to track browser instances
    property user_id : String

    # the chat session id the user is planning to use, the initial chat room
    property session_id : String? = nil

    @[JSON::Field(ignore_deserialize: true)]
    property contacted : Bool = false

    @[JSON::Field(ignore_deserialize: true)]
    property staff_user_id : String? = nil

    # as we don't care about this field anymore and don't want it saved in unmapped
    @[JSON::Field(ignore: true)]
    property captcha : String? = nil

    property connected : Bool = true

    def initialize(@user_id, @name, @email = nil, @phone = nil, @type = nil, @staff_user_id = nil, @text_chat_only = nil)
    end
  end

  struct MeetingSummary
    include JSON::Serializable

    getter pos_system : String
    getter call_count : Int32
    getter waiting_count : Int32
    getter participant_count : Int32
    getter longest_wait_time : Int64

    def initialize(@pos_system, @call_count, @participant_count, @waiting_count, @longest_wait_time)
    end
  end

  class Meeting
    include JSON::Serializable

    # webrtc_user_id => participant
    getter participants : Hash(String, Participant)
    getter session_id : String
    property system_id : String

    getter created_by_user_id : String

    @[JSON::Field(converter: Time::EpochConverter)]
    getter created_at : Time

    @[JSON::Field(converter: Time::EpochConverter)]
    getter updated_at : Time

    @[JSON::Field(ignore: true)]
    property conference : ConferenceDetails

    def initialize(@system_id, @conference, participant : Participant)
      session_id = participant.session_id
      raise "no session id provided for participant" unless session_id
      @session_id = session_id
      @created_at = @updated_at = Time.utc
      @created_by_user_id = participant.user_id
      @participants = {
        participant.user_id => participant,
      }
    end

    def initialize(@system_id, @session_id, @conference, participant : Participant)
      @created_at = @updated_at = Time.utc
      @created_by_user_id = participant.user_id
      @participants = {
        participant.user_id => participant,
      }
    end

    def add(participant : Participant) : Participant
      @participants[participant.user_id] = participant
      @participants[@created_by_user_id]?.try(&.contacted=(true))
      @updated_at = Time.utc
      participant
    end

    def remove(webrtc_user_id : String) : Participant?
      if participant = @participants.delete(webrtc_user_id)
        @updated_at = Time.utc
        participant
      end
    end

    def has_participant?(webrtc_user_id : String) : Participant?
      @participants[webrtc_user_id]?
    end

    def mark_participant_connected(webrtc_user_id : String, state : Bool) : String?
      if participant = has_participant?(webrtc_user_id)
        old_state = participant.connected
        participant.connected = state
        return system_id unless old_state == state
      end
    end

    def empty? : Bool
      @participants.empty?
    end
  end
end
