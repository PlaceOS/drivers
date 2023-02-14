require "placeos-driver"
require "./health_rooms_models.cr"

class Place::Chat::HealthRooms < PlaceOS::Driver
  descriptive_name "Health Chat Rooms"
  generic_name :ChatRoom

  default_settings({
    is_spec:   true,
    domain:    "domain",
    pool_size: 10,
  })

  def on_load
    on_update
  end

  def on_update
    is_spec = setting?(Bool, :is_spec) || false

    domain = setting(String, :domain)
    @pool_target_size = setting?(Int32, :pool_size) || 10

    schedule.clear
    schedule.every(5.minutes) { pool_cleanup }
    schedule.in(1.second) { pool_cleanup } unless is_spec

    monitoring = "#{domain}/guest/entry"
    self[:monitoring] = monitoring

    subscriptions.clear
    monitor(monitoring) { |_subscription, payload| new_guest(payload) }
  end

  protected def update_meeting_state(session_id, system_id = nil, old_system_id = nil) : Nil
    self[session_id] = @meeting_mutex.synchronize { @meetings[session_id]?.try(&.dup) }
    if old_system_id
      self[old_system_id] = @room_mutex.synchronize { @rooms[old_system_id]?.try(&.dup) }
    end
    if system_id
      self[system_id] = @room_mutex.synchronize { @rooms[system_id]?.try(&.dup) }
    end
  end

  # ================================================
  # CHAT ENTRY SIGNAL
  # ================================================

  accessor staff_api : StaffAPI_1

  protected def new_guest(payload : String)
    logger.debug { "[signal] new guest arrived: #{payload}" }
    room_guest = Hash(String, Participant).from_json payload
    room_guest.each do |system_id, guest|
      conference = pool_checkout_conference
      meeting = Meeting.new(system_id, conference, guest)
      session_id = meeting.session_id
      logger.info { "[meet] new guest has entered chat: #{guest.name}, user_id: #{guest.user_id}, session: #{session_id}" }

      # update the session hash
      @meeting_mutex.synchronize { @meetings[session_id] = meeting }

      # update the room
      sessions = [] of SessionId
      @room_mutex.synchronize do
        sessions = @rooms[system_id]? || sessions
        sessions << meeting.session_id
        @rooms[system_id] = sessions
      end

      # send the meeting details to the user
      schedule.in(2.seconds) do
        staff_api.transfer_user(guest.user_id, session_id, {
          space_id:  conference.space_id,
          guest_pin: conference.guest_pin,
        })
      end

      # update status
      update_meeting_state(session_id, system_id)
    end
  end

  # ================================================
  # MEETING MANAGEMENT
  # ================================================

  # session id == the webrtc session id
  alias SessionId = String

  # system id == room
  alias SystemId = String

  # session_id => connection_details
  @meetings : Hash(SessionId, Meeting) = {} of SessionId => Meeting
  @meeting_mutex = Mutex.new

  # system ids => session ids
  @rooms = Hash(SystemId, Array(SessionId)).new { |hash, key| hash[key] = [] of SessionId }
  @room_mutex = Mutex.new

  def meeting_move_room(session_id : String, system_id : String) : Bool
    old_system_id = nil
    moved = false

    @meeting_mutex.synchronize do
      # grab the room id from the meeting details
      if meeting = @meetings[session_id]?
        old_system_id = meeting.system_id
        meeting.system_id = system_id
        moved = true

        @room_mutex.synchronize do
          # move the meeting to a new room
          if room_sessions = @rooms[old_system_id]?
            room_sessions.delete(session_id)

            if room_sessions.empty?
              @rooms.delete(old_system_id)
              self[old_system_id] = nil
            end

            sessions = @rooms[system_id]? || [] of SessionId
            sessions << session_id
            @rooms[system_id] = sessions
          end
        end
      end
    end

    logger.debug { "[meet] moving session: #{session_id} to system #{system_id} from #{old_system_id}" }

    # update the system state
    update_meeting_state(session_id, system_id, old_system_id) if moved
    moved
  end

  # this is how staff members create a meeting room
  # or join an existing meeting
  def meeting_join(rtc_user_id : String, session_id : String, type : String? = nil, system_id : String? = nil) : ConferenceDetails
    placeos_user_id = invoked_by_user_id
    user_details = staff_api.user(placeos_user_id).get

    participant = Participant.new(
      user_id: rtc_user_id,
      name: user_details["name"].as_s,
      email: user_details["email"].as_s,
      type: type,
      staff_user_id: placeos_user_id
    )

    # TODO:: ensure the user has left any other room they might be in

    # check we have the information we need
    meeting = nil
    @meeting_mutex.synchronize do
      # check if we're joining an existing session
      if meeting = @meetings[session_id]?
        system_id = meeting.system_id
      end
    end

    raise "must provide a system id if there is not an existing session" unless system_id

    logger.debug do
      if meeting
        "[meet] joining existing meeting: staff #{placeos_user_id}, session: #{session_id} in #{system_id}"
      else
        "[meet] creating new meeting: staff #{placeos_user_id}, session: #{session_id} in #{system_id}"
      end
    end
    conference = pool_checkout_conference unless meeting

    @meeting_mutex.synchronize do
      # create a new meeting if required
      meeting = if meet = @meetings[session_id]?
                  system_id = meet.system_id
                  meet.add participant
                  meet
                else
                  # most likely won't have to checkout a conference here
                  conference = conference || pool_checkout_conference
                  Meeting.new(system_id.as(String), session_id, conference, participant)
                end
      @meetings[session_id] = meeting
      conference = meeting.conference

      @room_mutex.synchronize do
        sessions = @rooms[system_id]? || [] of SessionId
        sessions << session_id unless sessions.includes?(session_id)
        @rooms[system_id] = sessions
      end
    end

    # update status
    update_meeting_state(session_id, system_id.as(String))
    conference.as(ConferenceDetails)
  end

  def guest_mark_as_contacted(rtc_user_id : String, session_id : String, contacted : Bool = true) : Bool
    found = false
    @meeting_mutex.synchronize do
      if meeting = @meetings[session_id]?
        if participant = meeting.participants[rtc_user_id]?
          found = true
          participant.contacted = contacted
        end
      end
    end
    logger.debug { "[meet] marking guest #{rtc_user_id} as contacted: #{contacted} in session #{session_id}" }
    update_meeting_state(session_id) if found
    found
  end

  def guest_move_session(rtc_user_id : String, session_id : String, new_session_id : String) : Bool
    system_id = nil
    new_meeting = nil

    # move the meeting
    @meeting_mutex.synchronize do
      if (meeting = @meetings[session_id]?) && (new_meeting = @meetings[new_session_id]?)
        if participant = meeting.remove(rtc_user_id)
          system_id = meeting.system_id
          new_meeting.add participant

          if meeting.empty?
            @meetings.delete session_id
            @room_mutex.synchronize { @rooms[system_id].try(&.delete(session_id)) }
          end
        end
      end
    end

    # update state if the meeting was moved
    if system_id && new_meeting
      logger.debug { "[meet] moving guest #{rtc_user_id} into #{new_session_id} from #{session_id}" }
      update_meeting_state(session_id, system_id)
      update_meeting_state(new_session_id)

      # POST the update so the guest is aware of the new meeting details
      conference = new_meeting.conference
      staff_api.transfer_user(rtc_user_id, new_session_id, {
        space_id:  conference.space_id,
        guest_pin: conference.guest_pin,
      })
    else
      logger.warn { "[meet] failed to move guest #{rtc_user_id} as could not find session" }
    end
    !!system_id
  end

  # ================================================
  # MEETING POOL
  # ================================================
  accessor video_conference : InstantConnect_1

  @pool_lock : Mutex = Mutex.new
  @pool_meet : Array(ConferenceDetails) = [] of ConferenceDetails
  getter pool_size : Int32 = 0
  getter pool_target_size : Int32 = 10

  # how many new meetings do we need in the pool?
  # set the pool size counter eagerly and then get to work
  # this way concurrent calls to this function can occur
  # and we don't block anything with the fiber.
  #
  # if a new user joins and they don't have meeting details then we can
  # create them on the fly and not update the pool
  protected def new_conference
    logger.debug { "[pool] Creating new conference..." }
    room_id = UUID.random.to_s
    details = video_conference.create_meeting(room_id).get
    ConferenceDetails.new room_id, details["space_id"].as_s, details["host_token"].as_s, details["guest_token"].as_s
  end

  protected def pool_cleanup
    logger.debug { "[pool] Checking for expired meetings..." }
    expired = 12.hours.ago
    @pool_lock.synchronize do
      @pool_meet = @pool_meet.reject do |meeting|
        rejected = meeting.created_at < expired
        # we reduce the size of the pool here as technically we
        # could be running pool_ensure_size at the same time
        if rejected
          @pool_size -= 1
          new_size = @pool_size
          logger.debug { "[pool] --> Cleaning up expired meeting, pool size #{new_size}" }
        end
        rejected
      end
    end

    pool_ensure_size
  end

  def pool_ensure_size : Nil
    required = 0
    @pool_lock.synchronize do
      required = @pool_target_size - @pool_size
      @pool_size = @pool_target_size
    end

    logger.debug { "[pool] Maintaining meeting pool size, #{required} new meetings required" }
    return if required <= 0

    required.times do
      meeting = new_conference
      @pool_lock.synchronize { @pool_meet << meeting }
    end
  end

  def pool_checkout_conference : ConferenceDetails
    meeting = @pool_lock.synchronize do
      if @pool_meet.size > 0
        @pool_size -= 1
        @pool_meet.shift
      end
    end

    logger.debug { "[pool] Checking out meeting, available in pool? #{!meeting.nil?}" }
    spawn { pool_ensure_size }

    meeting || new_conference
  end

  def pool_clear_conferences : Nil
    logger.debug { "[pool] Clearing #{@pool_size} meetings from pool" }

    @pool_lock.synchronize do
      @pool_size = 0
      @pool_meet = [] of ConferenceDetails
    end

    pool_ensure_size
  end
end
