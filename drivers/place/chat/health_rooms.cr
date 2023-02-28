require "placeos-driver"
require "./health_rooms_models.cr"

class Place::Chat::HealthRooms < PlaceOS::Driver
  descriptive_name "Health Chat Rooms"
  generic_name :ChatRoom

  default_settings({
    is_spec:   true,
    domain_id: "domain",
    pool_size: 10,
    # disconnect time in minutes
    disconnect_timeout: 6,
  })

  def on_load
    on_update
  end

  @disconnect_timeout : Time::Span = 6.minutes

  def on_update
    logger.debug { "[admin] updating settings..." }
    is_spec = setting?(Bool, :is_spec) || false

    domain = setting(String, :domain_id)
    @pool_target_size = setting?(Int32, :pool_size) || 10
    system_id = config.control_system.not_nil!.id

    @disconnect_timeout = (setting?(Int32, :disconnect_timeout) || 6).minutes

    schedule.clear
    schedule.every(@disconnect_timeout / 3) { cleanup_disconnected }
    schedule.every(5.minutes) { pool_cleanup }
    schedule.in(1.second) { pool_cleanup } unless is_spec

    monitoring = "#{domain}/chat/#{system_id}/guest/entry"
    self[:monitoring] = monitoring

    subscriptions.clear
    monitor(monitoring) { |_subscription, payload| new_guest(payload) }
    monitor("#{domain}/chat/user/joined") { |_subscription, payload| user_joined(payload) }
    monitor("#{domain}/chat/user/exited") { |_subscription, payload| user_exited(payload) }
    monitor("#{domain}/chat/user/left") { |_subscription, payload| user_left(payload) }
    logger.debug { "[admin] settings update success!" }
  end

  protected def update_meeting_state(session_id, system_id = nil, old_system_id = nil) : Nil
    self[session_id] = @meeting_mutex.synchronize { @meetings[session_id]?.try(&.dup) }
    if old_system_id
      self[old_system_id] = @room_mutex.synchronize { @rooms[old_system_id]?.try(&.dup) }
    end
    if system_id
      self[system_id] = @room_mutex.synchronize { @rooms[system_id]?.try(&.dup) }
    end

    # update the overview of all the meetings
    # NOTE:: locks must be obtained in the same order as other places
    # in code to prevent deadlocks / invalid state
    summary = Array(MeetingSummary).new(@rooms.size)
    @meeting_mutex.synchronize do
      @room_mutex.synchronize do
        time_now = Time.utc.to_unix

        @rooms.each do |sys_id, sessions|
          total_participants = 0
          waiting = 0
          longest_wait = 0_i64
          number_calls = sessions.size

          sessions.each do |sesh_id|
            call_details = @meetings[sesh_id]
            num_participants = call_details.participants.size
            total_participants += num_participants
            initiator = call_details.participants[call_details.created_by_user_id]?
            if num_participants == 1 && initiator && !initiator.contacted
              waiting += 1
              waiting_time = call_details.updated_at.to_unix
              longest_wait = waiting_time if longest_wait == 0_i64 || waiting_time < longest_wait
            end
          end

          summary << MeetingSummary.new(sys_id, number_calls, total_participants, waiting, longest_wait)
        end
      end
    end

    self[:chat_summary] = {
      value:       summary,
      ts_hint:     "complex",
      ts_tag_keys: {"pos_system"},
      measurement: "chat_summary",
    }
  end

  # ================================================
  # CHAT ENTRY SIGNAL
  # ================================================

  accessor staff_api : StaffAPI_1

  protected def new_guest(payload : String)
    logger.debug { "[signal] new guest arrived: #{payload}" }
    room_guest = Hash(String, Participant).from_json payload
    system_id, guest = room_guest.first
    begin
      conference = pool_checkout_conference
      # guest JWT's are not needed
      # webex_guest_jwt = video_conference.create_guest_bearer(guest.user_id, guest.name).get.as_s

      register_new_guest(system_id, guest, conference)
    rescue error
      logger.error(exception: error) { "[meet] failed to obtain meeting details, kicking guest #{guest.name} (#{guest.user_id})" }
      staff_api.kick_user(guest.user_id, guest.session_id, "failed to allocate meeting")
    end
  end

  protected def register_new_guest(system_id, guest, conference)
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
  rescue error
    logger.fatal(exception: error) { "[meet] failure to setup guest conference" }

    # remove the user at from the chat
    session_id = guest.session_id.not_nil!
    staff_api.kick_user(guest.user_id, session_id, "failed to allocate meeting")

    # remove the user from the UI
    meeting_remove_user(guest.user_id, session_id)
  end

  # chat user id unique => disconnect time
  @recent_lock = Mutex.new
  @concurrent_flag = false
  @recently_disconnected = {} of String => Int64

  # if we missed a signal we want to check twice, to avoid race conditions
  # user => session_id
  @missed_connections = {} of String => String

  # in case we missed any signals from the backend (i.e. service crash)
  # and the users have not re-connected
  protected def check_disconnected
    # grab the current state of meetings
    connected = {} of String => Array(String)
    disconnected = {} of String => Array(String)

    @meeting_mutex.synchronize do
      @meetings.transform_values(&.participants.keys)
      @meetings.each do |system_id, meeting|
        conn = [] of String
        disc = [] of String
        meeting.participants.values.each do |par|
          if par.connected
            conn << par.user_id
          else
            disc << par.user_id
          end
        end
        connected[system_id] = conn
        disconnected[system_id] = disc
      end
    end

    # ensure we haven't missed any signals, compare API to our state
    old_missed = @missed_connections
    new_missed = {} of String => String

    connected.each do |session_id, connected_users|
      disconnected_users = disconnected[session_id]

      begin
        actual_users = staff_api.chat_members(session_id).get.as_a.map(&.as_s)

        # reject any users that have actually just moved
        connected_not_found = (connected_users - actual_users).reject! { |user_id| disconnected_users.includes?(user_id) || new_missed.delete(user_id) }
        disconnected_found = (disconnected_users & actual_users)

        # build a new not found list
        @recent_lock.synchronize do
          connected_not_found.each do |user_id|
            new_missed[user_id] = session_id unless old_missed[user_id]? || @recently_disconnected[user_id]?
          end
        end

        disconnected_found.each { |user_id| mark_user_as_connected(session_id, user_id) }
      rescue error
        logger.warn(exception: error) { "[cleanup] failed to obtain member list for #{session_id}" }
      end
    end

    # mark as disconnected users that are not connected
    disconneced = new_missed.keys & old_missed.keys
    disconneced.each do |user_id|
      new_missed.delete(user_id)

      begin
        session_id = old_missed[user_id]
        mark_user_as_disconnected(session_id, user_id)
      rescue
      end
    end

    logger.debug { "[cleanup] complete, found #{disconneced.size} missed disconnections" }

    # update missed connections
    @missed_connections = new_missed
  end

  protected def cleanup_disconnected : Nil
    logger.debug { "[cleanup] removing disconnected clients from meetings..." }

    # prevent concurrent running of this function
    @recent_lock.synchronize do
      return if @concurrent_flag
      @concurrent_flag = true
    end

    # find disconnected users who have timed out
    remove = [] of String
    expired = @disconnect_timeout.ago.to_unix
    @recent_lock.synchronize do
      @recently_disconnected.each do |user_id, disconnected|
        remove << user_id if disconnected <= expired
      end
      remove.each do |user_id|
        @recently_disconnected.delete user_id
      end
    end

    # find the sessions the users who are to be removed
    sessions = [] of Tuple(String, String)
    remove.each do |user_id|
      @meeting_mutex.synchronize do
        @meetings.each do |session_id, meeting|
          if meeting.has_participant? user_id
            sessions << {user_id, session_id}
            break
          end
        end
      end
    end

    # remove the timed out users from the meetings
    sessions.each { |user_details| meeting_remove_user(*user_details) }
    logger.debug { "[cleanup] removed #{sessions.size} users who have timed out" }
    check_disconnected
  ensure
    @recent_lock.synchronize { @concurrent_flag = false }
  end

  protected def user_joined(payload : String) : Nil
    logger.debug { "[signal] user joined: #{payload}" }
    session_user = Hash(String, String).from_json payload
    mark_user_as_connected *session_user.first
  end

  protected def mark_user_as_connected(session_id, user_id)
    # check if we have seen this user and re-instate the user
    @recent_lock.synchronize do
      @missed_connections.delete(user_id)
      @recently_disconnected.delete(user_id)
    end

    system_id = @meeting_mutex.synchronize do
      @meetings[session_id]?.try &.mark_participant_connected(user_id, true)
    end

    # update the state
    if system_id
      update_meeting_state(session_id, system_id)
    end
  end

  protected def user_left(payload : String)
    logger.debug { "[signal] user left: #{payload}" }
    session_user = Hash(String, String).from_json payload
    mark_user_as_disconnected *session_user.first
  end

  protected def user_exited(payload : String)
    logger.debug { "[signal] user exited: #{payload}" }
    session_user = Hash(String, String).from_json payload
    session_id, user_id = session_user.first
    meeting_remove_user(user_id, session_id)
  end

  protected def mark_user_as_disconnected(session_id, user_id)
    # check if the user is related to this system
    system_id = @meeting_mutex.synchronize do
      @meetings[session_id]?.try &.mark_participant_connected(user_id, false)
    end

    # update the state
    if system_id
      now = Time.utc.to_unix
      @recent_lock.synchronize { @recently_disconnected[user_id] = now }
      update_meeting_state(session_id, system_id)
    end
  end

  # ================================================
  # NOTIFICATIONS
  # ================================================

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
  def meeting_join(rtc_user_id : String, session_id : String, type : String? = nil, system_id : String? = nil, text_chat_only : Bool? = nil) : ConferenceDetails
    placeos_user_id = invoked_by_user_id
    user_details = staff_api.user(placeos_user_id).get
    user_name = user_details["name"].as_s

    participant = Participant.new(
      user_id: rtc_user_id,
      name: user_name,
      email: user_details["email"].as_s,
      type: type,
      staff_user_id: placeos_user_id,
      text_chat_only: text_chat_only
    )

    # TODO:: ensure the user has left any other room they might be in
    @recent_lock.synchronize { @recently_disconnected.delete(rtc_user_id) }

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

    # guest JWT's are not needed
    # webex_guest_jwt = video_conference.create_guest_bearer(placeos_user_id, user_name).get.as_s
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

  protected def meeting_remove_user(rtc_user_id : String, session_id : String, placeos_user_id : String? = nil)
    system_id = nil

    @recent_lock.synchronize { @recently_disconnected.delete(rtc_user_id) }
    @meeting_mutex.synchronize do
      # grab the meeting details
      meeting = @meetings[session_id]?
      raise "meeting not found" unless meeting
      system_id = meeting.system_id

      # ensure the current place user is the rtc_user_id
      if placeos_user_id
        participant = meeting.participants[rtc_user_id]
        owner_user_id = participant.staff_user_id
        raise "user #{placeos_user_id} attempting to leave on behalf of #{owner_user_id}" unless owner_user_id == placeos_user_id
      end

      # remove the participant
      meeting.remove rtc_user_id
      if meeting.empty?
        @meetings.delete session_id
        @room_mutex.synchronize do
          if sessions = @rooms[system_id]?
            sessions.delete(session_id)
            @rooms.delete(system_id) if sessions.empty?
          end
        end
      end
    end

    # update status
    update_meeting_state(session_id, system_id.as(String))
  end

  # the user is planning of leaving the meeting or has left
  def meeting_leave(rtc_user_id : String, session_id : String) : Nil
    placeos_user_id = invoked_by_user_id
    logger.debug { "[meet] user leaving #{rtc_user_id} (#{placeos_user_id}) session #{session_id}" }

    meeting_remove_user(rtc_user_id, session_id, placeos_user_id)
  end

  # kicks an individual from a meeting
  def meeting_kick(rtc_user_id : String, session_id : String)
    placeos_user_id = invoked_by_user_id
    logger.warn { "[meet] kicking user #{rtc_user_id} from session #{session_id}, kicked by: #{placeos_user_id}" }

    # remove the user at from the chat
    staff_api.kick_user(rtc_user_id, session_id, "kicked by host")

    # remove the user from the UI
    meeting_remove_user(rtc_user_id, session_id)
  end

  # removes the meeting from the list and kicks anyone left in the meeting
  def meeting_end(session_id : String)
    placeos_user_id = invoked_by_user_id
    system_id = nil
    meeting = nil
    logger.debug { "[meet] ending meeting #{session_id} ended by #{placeos_user_id}" }

    # remove the meeting
    @meeting_mutex.synchronize do
      # grab the meeting details
      meeting = @meetings.delete session_id
      raise "meeting not found" unless meeting
      system_id = meeting.system_id

      @room_mutex.synchronize do
        if sessions = @rooms[system_id]?
          sessions.delete(session_id)
          @rooms.delete(system_id) if sessions.empty?
        end
      end
    end

    # kick the users to notify them that the meeting has ended
    meeting.not_nil!.participants.keys.each do |rtc_user_id|
      staff_api.kick_user(rtc_user_id, session_id, "meeting ended")
    end

    # update status
    update_meeting_state(session_id, system_id.as(String))
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

    if @recent_lock.synchronize { @recently_disconnected[rtc_user_id]? }
      logger.warn { "[meet] failed to move guest #{rtc_user_id} as disconnected" }
      raise "can't move disconnected users, please wait for reconnection or kick"
    end

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
      logger.debug { "[meet] moving user #{rtc_user_id} into #{new_session_id} from #{session_id}" }
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
    # calculate the number of meetings required
    required = 0
    @pool_lock.synchronize do
      required = @pool_target_size - @pool_size
      @pool_size = @pool_target_size
    end

    logger.debug { "[pool] Maintaining meeting pool size, #{required} new meetings required" }
    return if required <= 0

    # create the desired number of meetings
    created = 0
    begin
      required.times do
        meeting = new_conference
        @pool_lock.synchronize { @pool_meet << meeting }
        created += 1
      end
    rescue error
      logger.error(exception: error) { "[pool] error creating pool meetings" }

      # adjust size if pool update failed
      if created != required
        diff = required - created
        @pool_lock.synchronize { @pool_size = @pool_size - diff }
      end
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
