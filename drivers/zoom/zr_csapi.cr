require "placeos-driver"

# Driver for Zoom Room ZR-CSAPI (Legacy SSH Control System API)
# Connects to Zoom Room machines via SSH on port 2244
# API Documentation: https://developers.zoom.us/docs/rooms/cli/
class Zoom::ZrCSAPI < PlaceOS::Driver
  descriptive_name "Zoom Room ZR-CSAPI"
  generic_name :ZoomCSAPI
  description "Legacy SSH-based API for Zoom Rooms. Requires SSH credentials configured on the Zoom Room."

  tcp_port 2244

  default_settings({
    ssh: {
      username: "zoom",
      password: "",
    },
    enable_debug_logging: false,
    milliseconds_until_response: 500,
  })

  getter? ready : Bool = false
  @debug_enabled : Bool = false
  @response_delay : Int32 = 500
  @current_time : Int64 = Time.utc.to_unix

  def on_load
    queue.wait = false
    queue.delay = 10.milliseconds
    self[:ready] = @ready = false
    on_update
  end

  def on_update
    @debug_enabled = setting?(Bool, :enable_debug_logging) || false
    @response_delay = setting?(Int32, :milliseconds_until_response) || 500
  end

  def connected
    reset_connection_flags
    # schedule.in(5.seconds) do
    #   initialize_tokenizer unless @ready || @init_called
    # end
    # we need to disconnect if we don't see welcome message
    schedule.in(9.seconds) do
      if !ready?
        logger.error { "ZR-CSAPI connection failed to be ready after 9 seconds." }
        disconnect
      end
    end
    logger.debug { "Connected to Zoom Room ZR-CSAPI" }
    self[:connected] = true
  end

  def disconnected
    reset_connection_flags
    queue.clear abort_current: true
    schedule.clear
    logger.debug { "Disconnected from Zoom Room ZR-CSAPI" }
    self[:connected] = false
  end

  def fetch_initial_state
    update_current_time
    bookings_update
    call_status
  end 

  # =================
  # zCommand Methods - Meeting Control
  # =================

  # Get today's meetings scheduled for this room
  def bookings_list
    do_send("zCommand Bookings List", name: "bookings_list")
    sleep @response_delay.milliseconds
    expose_custom_bookings_list
    self["BookingsListResult"]
  end

  def update_current_time
  @current_time = Time.utc.to_unix;
  self[:meeting_started_time] = @current_time
  end

  # Expose custom booking JSON, filter meetings whose meetingNumber == 0 (invalid)
  # filter meetings whose endTime has already passed (completely finished)
  private def expose_custom_bookings_list
    bookings = self["BookingsListResult"]?
    return unless bookings
    
    # Get current time as unix timestamp for filtering
    update_current_time
    
    self[:Bookings] = bookings.as_a.compact_map { |b| 
      booking_hash = b.as_h
      
      # Parse ISO 8601 times and convert to unix timestamps
      start_time_iso = booking_hash["startTime"]?.try(&.as_s)
      end_time_iso = booking_hash["endTime"]?.try(&.as_s)
      
      next unless start_time_iso && end_time_iso
      
      begin
        start_time_unix = Time.parse_iso8601(start_time_iso).to_unix
        end_time_unix = Time.parse_iso8601(end_time_iso).to_unix
        
        # Filter out bookings whose start time has already elapsed
        next if end_time_unix < @current_time
        
        # Filter out entries whose meeting number is "0"
        meeting_number = booking_hash["meetingNumber"]?
        next if meeting_number == "0"
        
        # Return booking with converted unix timestamps
        {
          "creatorName" => booking_hash["creatorName"]?,
          "startTime" => start_time_unix,
          "endTime" => end_time_unix,
          "meetingName" => booking_hash["meetingName"]?,
          "meetingNumber" => booking_hash["meetingNumber"]?
        }
      rescue Time::Format::Error
        # Skip bookings with invalid time formats
        next
      end
    }.compact
  end

  # Update/refresh the meeting list from calendar
  def bookings_update
    do_send("zCommand Bookings Update", name: "bookings_update")
    sleep @response_delay.milliseconds
    bookings_list
  end

  # Start or join a meeting
  def dial_start(meeting_number : String)
    command = "zCommand Dial Start meetingNumber: #{meeting_number}"
    do_send(command, name: "dial_start")
    sleep @response_delay.milliseconds
    self["Call"]
    bookings_list
  end

  # Join a meeting
  def dial_join(meeting_number : String)
    command = "zCommand Dial Join meetingNumber: #{meeting_number}"
    do_send(command, name: "dial_join")
    sleep @response_delay.milliseconds
    self["Call"]
    bookings_list
  end

  # Join meeting via SIP
  def dial_join_sip(sip_address : String, protocol : String = "Auto")
    do_send("zCommand Dial Join meetingAddress: #{sip_address} protocol: #{protocol}", name: "dial_join_sip")
    sleep @response_delay.milliseconds
    self["Call"]
    bookings_list
  end

  # Start PMI meeting
  def dial_start_pmi(duration_minutes : Int32 = 15)
    command = "zCommand Dial StartPmi Duration: #{duration_minutes}"
    do_send(command, name: "dial_start_pmi")
    sleep @response_delay.milliseconds
    self["Call"]
    bookings_list
  end

  # Input meeting password
  def input_password(password : String)
    do_send("zCommand Input Meeting Password: #{password}", name: "input_password")
  end

  # Leave current meeting
  def call_disconnect
    do_send("zCommand Call Disconnect", name: "call_disconnect")
  end

  # Invite participant to meeting
  def call_invite(user : String)
    do_send("zCommand Call Invite user: #{user}", name: "call_invite")
  end

  # Mute/unmute specific participant audio
  def call_mute_participant_audio (mute : Bool, participant_id : String)
    state = mute ? "on" : "off"
    do_send("zCommand Call MuteParticipant mute: #{state} Id: #{participant_id}", name: "call_mute_participant_audio")
  end

    # Mute/unmute specific participant video
  def call_mute_participant_video (mute : Bool, participant_id : String)
    state = mute ? "on" : "off"
    do_send("zCommand Call MuteParticipantVideo mute: #{state} Id: #{participant_id}", name: "call_mute_participant_video")
  end

  # Mute/unmute all participants
  def call_mute_all(mute : Bool)
    state = mute ? "on" : "off"
    do_send("zCommand Call MuteAll mute: #{state}", name: "call_mute_all")
  end

  # Mute/unmute self (room microphone)
  def call_mute_self(mute : Bool)
    state = mute ? "on" : "off"
    do_send("zConfiguration Call Microphone Mute: #{state}", name: "call_mute_self")
  end

  # Mute/unmute self (camera)
  def call_mute_camera(mute : Bool)
    state = mute ? "on" : "off"
    do_send("zConfiguration Call Camera Mute: #{state}", name: "call_mute_camera")
    sleep @response_delay.milliseconds
    self["Call"]
  end

  # Start/stop recording
  def call_record(enable : Bool)
    state = enable ? "on" : "off"
    do_send("zCommand Call Record Enable: #{state}", name: "call_record")
  end

  # Change meeting host
  def call_make_host(participant_id : String)
    do_send("zCommand Call MakeHost Id: #{participant_id}", name: "call_make_host")
  end

  # Pin participant video
  def call_pin_participant(pin : Bool, participant_id : String)
    state = pin ? "on" : "off"
    do_send("zCommand Call PinParticipant Pin: #{state} Id: #{participant_id}", name: "call_pin_participant")
  end

  # Spotlight participant
  def call_spotlight_participant(spotlight : Bool, participant_id : String)
    state = spotlight ? "on" : "off"
    do_send("zCommand Call SpotlightParticipant Spotlight: #{state} Id: #{participant_id}", name: "call_spotlight_participant")
  end

  # Lock/unlock meeting
  def call_lock(lock : Bool)
    state = lock ? "on" : "off"
    do_send("zCommand Call Lock Enable: #{state}", name: "call_lock")
  end

  # Enable/disable waiting room
  def call_waiting_room(enable : Bool)
    state = enable ? "on" : "off"
    do_send("zCommand Call WaitingRoom Enable: #{state}", name: "call_waiting_room")
  end

  # Admit participant from waiting room
  def call_admit_participant(participant_id : String)
    do_send("zCommand Call Admit Participant: #{participant_id}", name: "call_admit_participant")
  end

  # Expel participant from meeting
  def call_expel_participant(participant_id : String)
    do_send("zCommand Call Expel Id: #{participant_id}", name: "call_expel_participant")
  end

  # Change video layout
  def call_layout(layout_style : String, layout_size : String? = nil, layout_position : String? = nil)
    command = "zCommand Call Layout LayoutStyle: #{layout_style}"
    command += " LayoutSize: #{layout_size}" if layout_size
    command += " LayoutPosition: #{layout_position}" if layout_position
    do_send(command, name: "call_layout")
  end

  # List phonebook contacts
  def phonebook_list
    do_send("zCommand Phonebook List", name: "phonebook_list")
  end

  # Search phonebook
  def phonebook_search(search_string : String)
    do_send("zCommand Phonebook Search SearchString: #{search_string}", name: "phonebook_search")
  end

  # =================
  # zCommand Methods - Sharing Control
  # =================

  # Start/stop HDMI sharing
  def sharing_start_hdmi
    do_send("zCommand Call Sharing HDMI Start", name: "sharing_start_hdmi")
    sleep @response_delay.milliseconds
    self["SharingState"]
  end

  def sharing_stop
    do_send("zCommand Call Sharing HDMI Stop", name: "sharing_stop_hdmi")
    sleep @response_delay.milliseconds
    self["SharingState"]
  end

  # Stop sharing Wireless
  def sharing_stop_wireless
    do_send("zCommand Call Sharing Disconnect", name: "sharing_stop_wireless")
    sleep @response_delay.milliseconds
    self["Sharing"]
  end

  # Share camera
  def sharing_start_camera(camera_id : String, enable : Bool)
    state = enable ? "on" : "off"
    do_send("zCommand Call ShareCamera id: #{camera_id} Status: #{state}", name: "sharing_camera")
  end

  # =================
  # zCommand Methods - Device Testing
  # =================

  # Test microphone
  def test_microphone_start(device_id : String? = nil)
    command = "zCommand Test Microphone Start"
    command += " Id: #{device_id}" if device_id
    do_send(command, name: "test_microphone_start")
  end

  def test_microphone_stop
    do_send("zCommand Test Microphone Stop", name: "test_microphone_stop")
  end

  # Test speakers
  def test_speakers_start(device_id : String? = nil)
    command = "zCommand Test Speakers Start"
    command += " Id: #{device_id}" if device_id
    do_send(command, name: "test_speakers_start")
  end

  def test_speakers_stop
    do_send("zCommand Test Speakers Stop", name: "test_speakers_stop")
  end

  # Test camera
  def test_camera_start(device_id : String? = nil)
    command = "zCommand Test Camera Start"
    command += " Id: #{device_id}" if device_id
    do_send(command, name: "test_camera_start")
  end

  def test_camera_stop
    do_send("zCommand Test Camera Stop", name: "test_camera_stop")
  end

  # =================
  # zStatus Methods
  # =================

  def system_unit?
    do_send("zStatus SystemUnit", name: "status_system_unit")
    sleep @response_delay.milliseconds
    self["SystemUnit"]
  end

  # Get call status
  def call_status
    do_send("zStatus Call Status", name: "call_status")
    sleep @response_delay.milliseconds
    self["Call"]
  end

  # Get call stats information
  def call_stats
    do_send("zStatus Call Stats", name: "call_stats")
  end

  # Get participant list
  def call_list_participants
    logger.debug { "=== CALLING call_list_participants ===" }
    do_send("zCommand Call ListParticipants", name: "call_participants")
    sleep @response_delay.milliseconds
    self["ListParticipantsResult"]
  end
 
  #Expose ListParticipantsResult in a more easily read and usable format
  private def expose_custom_participant_list
    participants = self["ListParticipantsResult"]?
    return unless participants
    
    participants_array = participants.as_a
    self[:number_of_participants] = participants_array.size
    
    # selected participants
    selected_participants = participants_array.map { |p| p.as_h.select(
      "user_id",
      "user_name",
      "audio_status state",
      "video_status has_source",
      "video_status is_sending",
      "isCohost",
      "is_host",
      "is_in_waiting_room",
      "hand_status"
    )}
    
    # transform
    self[:Participants] = selected_participants.map do |participant|
      {
        "user_id" => participant["user_id"],
        "user_name" => participant["user_name"],
        "audio_state" => participant["audio_status state"],
        "video_has_source" => participant["video_status has_source"],
        "video_is_sending" => participant["video_status is_sending"],
        "isCohost" => participant["isCohost"],
        "is_host" => participant["is_host"],
        "is_in_waiting_room" => participant["is_in_waiting_room"],
        "hand_status" => participant["hand_status"]
      }
    end
  end

  private def expose_custom_call_state
    return unless call = self[:Call]
    
    call_state = call.dig?("Status")
    self[:in_call] = call_state.as_s? == "IN_MEETING" if call_state
    
    mic_state = call.dig?("Microphone", "Mute")
    self[:mic_mute] = mic_state.as_bool? if mic_state

    cam_state = call.dig?("Camera", "Mute")
    self[:cam_mute] = cam_state.as_bool? if cam_state

  end

  # Get audio input devices
  def audio_input_line
    do_send("zStatus Audio Input Line", name: "audio_input_line")
  end

  # Get audio output devices
  def audio_output_line
    do_send("zStatus Audio Output Line", name: "audio_output_line")
  end

  # Get video camera devices
  def video_camera_line
    do_send("zStatus Video Camera Line", name: "video_camera_line")
  end

  # Get system capabilities
  def capabilities
    do_send("zStatus Capabilities", name: "capabilities")
  end

  # Get sharing status
  def sharing_status
    do_send("zStatus Sharing", name: "sharing_status")
  end

  # Get room info
  def room_info
    do_send("zStatus RoomInfo", name: "room_info")
  end

  # Get peripherals
  def peripherals
    do_send("zStatus Peripherals", name: "peripherals")
  end

  # =================
  # zConfiguration Methods
  # =================

  # Audio Configuration
  def config_audio_input(device_id : String? = nil)
    if device_id
      do_send("zConfiguration Audio Input selectedDevice: #{device_id}", name: "config_audio_input")
    else
      do_send("zConfiguration Audio Input selectedDevice", name: "config_audio_input")
    end
  end

  def config_audio_output(device_id : String? = nil)
    if device_id
      do_send("zConfiguration Audio Output selectedDevice: #{device_id}", name: "config_audio_output")
    else
      do_send("zConfiguration Audio Output selectedDevice", name: "config_audio_output")
    end
  end

  def config_audio_volume(volume : Int32)
    if volume
      do_send("zConfiguration Audio Output volume: #{volume}", name: "config_audio_volume")
    else
      do_send("zConfiguration Audio Output volume", name: "config_audio_volume")
    end
  end

  def config_audio_reduce_reverb(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Audio Input ReduceReverb", name: "config_audio_reduce_reverb")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Audio Input ReduceReverb: #{state}", name: "config_audio_reduce_reverb")
    end
  end

  def config_audio_software_processing(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Audio Input SoftwareAudioProcessing", name: "config_audio_software_processing")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Audio Input SoftwareAudioProcessing: #{state}", name: "config_audio_software_processing")
    end
  end

  # Video Configuration
  def config_video_camera(device_id : String? = nil)
    if device_id
      do_send("zConfiguration Video Camera selectedDevice: #{device_id}", name: "config_video_camera")
    else
      do_send("zConfiguration Video Camera selectedDevice", name: "config_video_camera")
    end
  end

  def config_video_self_view(hide : Bool? = nil)
    if hide.nil?
      do_send("zConfiguration Video selfViewHide", name: "config_video_self_view")
    else
      state = hide ? "on" : "off"
      do_send("zConfiguration Video selfViewHide: #{state}", name: "config_video_self_view")
    end
  end

  def config_video_mirror_mode(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Video Camera mirrorMode", name: "config_video_mirror_mode")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Video Camera mirrorMode: #{state}", name: "config_video_mirror_mode")
    end
  end

  # Call Configuration
  def config_call_mute_on_entry(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Call muteUserOnEntry", name: "config_call_mute_on_entry")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Call muteUserOnEntry: #{state}", name: "config_call_mute_on_entry")
    end
  end

  def config_call_lock_enable(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Call Lock enable", name: "config_call_lock")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Call Lock enable: #{state}", name: "config_call_lock")
    end
  end

  def config_call_layout(layout_style : String? = nil, layout_size : String? = nil, layout_position : String? = nil)
    if layout_style
      command = "zConfiguration Call Layout LayoutStyle: #{layout_style}"
      command += " LayoutSize: #{layout_size}" if layout_size
      command += " LayoutPosition: #{layout_position}" if layout_position
      do_send(command, name: "config_call_layout")
    else
      do_send("zConfiguration Call Layout", name: "config_call_layout")
    end
  end

  def config_call_share_thumb(size : String? = nil, position : String? = nil)
    if size || position
      command = "zConfiguration Call Layout ShareThumb"
      command += " Size: #{size}" if size
      command += " Position: #{position}" if position
      do_send(command, name: "config_call_share_thumb")
    else
      do_send("zConfiguration Call Layout ShareThumb", name: "config_call_share_thumb")
    end
  end

  # Closed Caption Configuration
  def config_call_closed_caption_visible(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Call ClosedCaption Visible", name: "config_closed_caption_visible")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Call ClosedCaption Visible: #{state}", name: "config_closed_caption_visible")
    end
  end

  def config_call_closed_caption_font_size(size : Int32? = nil)
    if size
      do_send("zConfiguration Call ClosedCaption FontSize: #{size}", name: "config_closed_caption_font_size")
    else
      do_send("zConfiguration Call ClosedCaption FontSize", name: "config_closed_caption_font_size")
    end
  end

  # Client Information
  def config_client_app_version
    do_send("zConfiguration Client appVersion", name: "config_client_app_version")
  end

  def config_client_device_system
    do_send("zConfiguration Client deviceSystem", name: "config_client_device_system")
  end

  # Sharing Configuration
  def config_sharing_participant(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Sharing Participant", name: "config_sharing_participant")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Sharing Participant: #{state}", name: "config_sharing_participant")
    end
  end

  def config_sharing_optimize_video(enable : Bool? = nil)
    if enable.nil?
      do_send("zConfiguration Sharing optimizeVideo", name: "config_sharing_optimize_video")
    else
      state = enable ? "on" : "off"
      do_send("zConfiguration Sharing optimizeVideo: #{state}", name: "config_sharing_optimize_video")
    end
  end

  def send_command(command : String)
    transport.send "#{command}\r\n"
  end

  protected def reset_connection_flags
    self[:ready] = @ready = false
    @init_called = false
    transport.tokenizer = nil
  end

  # Regexp's for tokenizing the ZR-CSAPI response structure.
  INVALID_COMMAND  = /(?<=onUnsupported Command)[\r\n]+/
  SUCCESS          = /(?<=OK)[\r\n]+/
  COMMAND_RESPONSE = Regex.union(INVALID_COMMAND, SUCCESS)

  private def initialize_tokenizer
    @init_called = true
    transport.tokenizer = Tokenizer.new do |io|
      raw = io.gets_to_end
      data = raw.lstrip
      index = if data.includes?("{")
                count = 0
                pos = 0
                data.each_char_with_index do |char, i|
                  pos = i
                  count += 1 if char == '{'
                  count -= 1 if char == '}'
                  break if count.zero?
                end
                pos if count.zero?
              else
                data =~ COMMAND_RESPONSE
              end
      if index
        message = data[0..index]
        index += raw.byte_index_to_char_index(raw.byte_index(message).not_nil!).not_nil!
        index = raw.char_index_to_byte_index(index + 1)
      end
      index || -1
    end
    self[:ready] = @ready = true
  rescue error
    @init_called = false
    logger.warn(exception: error) { "error configuring zrcsapi transport" }
  end

  def received(data, task)
    response = String.new(data).strip.delete &.in?('\r', '\n')
    logger.debug { "Received: #{response.inspect}" } if @debug_enabled

    unless ready?
      if response.includes?("ZAAPI") # Initial connection message
        queue.clear abort_current: true
        do_send("echo off", name: "echo_off")
        schedule.clear
        do_send("format json", name: "set_format")
        schedule.clear
        initialize_tokenizer unless @init_called
        fetch_initial_state
      else
        return task.try(&.abort)
      end
    end

    # Ignore non-JSON messages
    if response[0] == '{'
      task.try &.success(response)
    else
      return
    end

    json_response = JSON.parse(response)
    response_type : String = json_response["type"].as_s
    response_topkey : String = json_response["topKey"].as_s
    if @debug_enabled
      logger.debug { "type: #{response_type}, topkey: #{response_topkey}" }
    end

    # Expose new data as status variables
    begin
      old_data = self[response_topkey]
      new_data = json_response[response_topkey].as_h
      logger.debug { "Merging new data into existing data" } if @debug_enabled
      self[response_topkey] = old_data.as_h.merge(new_data)
    rescue exception
      logger.debug { "Replacing existing data" } if @debug_enabled
      self[response_topkey] = json_response[response_topkey]
    end

    case response_topkey
    when "Call"
      expose_custom_call_state
    when "ListParticipantsResult"
      begin
        list = json_response["ListParticipantsResult"]
        event = nil
        
        # Handle different data structures correctly
        if list.as_a?
          # It's an array (manual query response) - get event from first participant
          first_participant = list.as_a.first?
          if first_participant && first_participant.as_h?
            event_value = first_participant.as_h["event"]?
            event = event_value.try(&.as_s) if event_value
          end
        elsif list.as_h?
          # It's a single hash (automatic event) - get event directly
          event_value = list.as_h["event"]?
          event = event_value.try(&.as_s) if event_value
        end
        
        logger.info { "Final event: #{event}" }
        
        # Handle the event properly
        if event == "None" && list.as_a?
          # Manual query response - process the participant list
          logger.info { "Processing manual query response" }
          expose_custom_participant_list
        elsif event && event.starts_with?("ZRCUserChangedEvent")
          # Automatic event - trigger fresh query
          logger.info { "Triggering auto-refresh for: #{event}" }
          call_list_participants
        end
        
      rescue ex
        logger.error { "Error processing ListParticipantsResult: #{ex.message}" }
      end
    end

    # Perform additional actions
    case response_type
    when "zEvent"
      case response_topkey
      when "Bookings Updated"
        bookings_list
      end
    when "zStatus"
      case response_topkey
      when "Call"
        expose_custom_call_state
      end
    when "zConfiguration"
    when "zCommand"
    end
  end

  private def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send "#{command}\r\n", **options
  end
end
