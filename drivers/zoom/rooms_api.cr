require "placeos-driver"
require "base64"
require "json"
require "jwt"

# Documentation: https://developers.zoom.us/docs/api/rooms/

class Zoom::RoomsApi < PlaceOS::Driver
  descriptive_name "Zoom Rooms Cloud REST API"
  generic_name :ZoomRooms
  description %(
    Zoom Rooms Cloud REST API Control driver for managing and controlling Zoom Room devices.

    Requirements:
    - OAuth 2.0 authentication (Server-to-Server OAuth app recommended)
    - Required scopes: room:read:admin, room:write:admin, zoom_rooms:update:room_control:admin
    - Calendar API access (Microsoft Exchange or Google Calendar) for room check-in/out features
  )

  uri_base "https://api.zoom.us"

  default_settings({
    account_id:    "your_account_id",
    client_id:     "your_client_id",
    client_secret: "your_client_secret",
    room_id:       "optional_default_room_id",
  })

  def on_load
    on_update
  end

  def on_update
    # Read settings
    @account_id = setting(String, :account_id)
    @client_id = setting(String, :client_id)
    @client_secret = setting(String, :client_secret)
    @default_room_id = setting?(String, :room_id)
  end

  @account_id : String = ""
  @client_id : String = ""
  @client_secret : String = ""
  @default_room_id : String? = nil
  getter! auth_token : AccessToken

  record AccessToken, access_token : String, token_type : String, expires_in : Int32, scope : String?, api_url : String do
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter! expiry : Time

    def after_initialize
      @expiry = Time.utc + expires_in.seconds
    end

    def expired?
      1.minute.from_now > expiry
    end
  end

  # Authentication
  private def authenticate : String
    if auth_token?.nil? || (auth_token? && auth_token.expired?)
      token_url = "https://zoom.us/oauth/token"
      http_uri_override = "https://zoom.us"
      body = URI::Params.build do |form|
        form.add("grant_type", "account_credentials")
        form.add("account_id", @account_id)
      end
      response = post(
        "/oauth/token",
        headers: HTTP::Headers{
          "Authorization" => "Basic #{Base64.strict_encode("#{@client_id}:#{@client_secret}")}",
          "Content-Type"  => "application/x-www-form-urlencoded",
        },
        body: body
      )

      if response.success?
        logger.debug { "Successfully authenticated with Zoom API:\n#{response.body}" }
        @auth_token = AccessToken.from_json(response.body)

        # TODO:: fix this, needs to be against the transport
        http_uri_override = auth_token.api_url
      else
        logger.error { "Failed to authenticate: #{response.status_code}\n#{response.body}" }
        raise "Authentication failed: #{response.status_code}, response: #{response.body}"
      end
    end
    auth_token.access_token
  end

  private def api_request(method : String, resource : String, body : JSON::Any? = nil, params : Hash(String, String)? = nil)
    token = authenticate

    headers = {
      "Authorization" => "Bearer #{token}",
      "Content-Type"  => "application/json",
    }
    resource = "/v2#{resource}"
    response = case method.downcase
               when "get"
                 params ? get(resource, headers: headers, params: params) : get(resource, headers: headers)
               when "post"
                 post(resource, headers: headers, body: body.try(&.to_json))
               when "patch"
                 patch(resource, headers: headers, body: body.try(&.to_json))
               when "delete"
                 delete(resource, headers: headers)
               else
                 raise "Unsupported HTTP method: #{method}"
               end

    unless response.success?
      logger.error { "API request failed: #{method} #{resource} - #{response.status_code} - #{response.body}" }
      raise "API request failed: #{response.status_code}, response: #{response.body}"
    end

    JSON.parse(response.body) unless (response.body.nil? || response.body.empty?)
  end

  # List Zoom Rooms
  def list_rooms(
    status : String? = nil,
    type : String? = nil,
    location_id : String? = nil,
    page_size : Int32 = 30,
    next_page_token : String? = nil,
  )
    params = {} of String => String
    params["status"] = status if status
    params["type"] = type if type
    params["location_id"] = location_id if location_id
    params["page_size"] = page_size.to_s
    params["next_page_token"] = next_page_token if next_page_token

    result = api_request("GET", "/rooms", params: params)
    self[:rooms] = result.try(&.["rooms"])
    result
  end

  # Get specific room details
  # the user_id in this response can be used to get the upcoming meetings
  # https://developers.zoom.us/docs/api/rooms/#tag/zoom-rooms/GET/rooms/{roomId}
  def get_room(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}")
    self[:room_details] = result
    result
  end

  enum MeetingType
    Scheduled        # All valid previous (unexpired) meetings, live meetings, and upcoming scheduled meetings.
    Live             # All the ongoing meetings
    Upcoming         # All upcoming meetings, including live meetings.
    UpcomingMeetings # All upcoming meetings, including live meetings.
    PreviousMeetings # All the previous meetings.
  end

  # list the meetings in the room
  # https://developers.zoom.us/docs/api/meetings/#tag/meetings/GET/users/{userId}/meetings
  def list_meetings(room_user_id : String, type : MeetingType = MeetingType::Scheduled)
    params = {
      "type" => type.to_s.underscore,
    }
    api_request("GET", "/users/#{room_user_id}/meetings", params: params)
  end

  # List Zoom Room devices
  def list_devices(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}/devices")
    self[:devices] = result.try(&.["devices"])
    result
  end

  # Get device information
  def get_device_info(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}/device_profiles/devices")
    self[:device_info] = result
    result
  end

  # List device profiles
  def list_device_profiles(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}/device_profiles")
    self[:device_profiles] = result.try(&.["device_profiles"])
    result
  end

  # Get Zoom Room sensor data
  def get_sensor_data(room_id : String? = nil, from : String? = nil, to : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    params = {} of String => String
    params["from"] = from if from
    params["to"] = to if to

    result = api_request("GET", "/rooms/#{room_id}/sensor_data", params: params)
    self[:sensor_data] = result
    result
  end

  # Get Zoom Room settings
  def get_room_settings(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}/settings")
    self[:room_settings] = result
    result
  end

  # Room Controls - Mute/Unmute microphone
  def mute(state : Bool = true, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    method = state ? "zoomroom.mute" : "zoomroom.unmute"
    body = JSON.parse({
      "method" => method,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:muted] = state
    logger.debug { "Microphone #{state ? "muted" : "unmuted"}" }
    nil
  end

  def unmute(room_id : String? = nil)
    mute(false, room_id)
  end

  # Video mute/unmute
  def video_mute(state : Bool = true, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    method = state ? "zoomroom.video_mute" : "zoomroom.video_unmute"
    body = JSON.parse({
      "method" => method,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:video_muted] = state
    logger.debug { "Video #{state ? "muted" : "unmuted"}" }
    nil
  end

  def video_unmute(room_id : String? = nil)
    video_mute(false, room_id)
  end

  # Restart Zoom Room
  def restart_room(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    body = JSON.parse({
      "method" => "zoomroom.restart",
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.info { "Zoom Room restart initiated" }
    nil
  end

  # Meeting controls
  def leave_meeting(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    body = JSON.parse({
      "method" => "zoomroom.meeting_leave",
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:in_meeting] = false
    logger.info { "Left meeting" }
    nil
  end

  def join_meeting(meeting_number : String, password : String? = nil, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    params = {
      "meeting_number" => meeting_number,
    }
    params["password"] = password if password

    body = JSON.parse({
      "method" => "zoomroom.meeting_join",
      "params" => params,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:in_meeting] = true
    logger.info { "Joined meeting #{meeting_number}" }
    nil
  end

  # Device switching
  def switch_camera(camera_id : String, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    body = JSON.parse({
      "method" => "zoomroom.switch_camera",
      "params" => {
        "camera_id" => camera_id,
      },
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:active_camera] = camera_id
    logger.debug { "Switched to camera #{camera_id}" }
    nil
  end

  def switch_microphone(microphone_id : String, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    body = JSON.parse({
      "method" => "zoomroom.switch_microphone",
      "params" => {
        "microphone_id" => microphone_id,
      },
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:active_microphone] = microphone_id
    logger.debug { "Switched to microphone #{microphone_id}" }
    nil
  end

  def switch_speaker(speaker_id : String, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    body = JSON.parse({
      "method" => "zoomroom.switch_speaker",
      "params" => {
        "speaker_id" => speaker_id,
      },
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:active_speaker] = speaker_id
    logger.debug { "Switched to speaker #{speaker_id}" }
    nil
  end

  # Content sharing
  def share_content(state : Bool = true, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    method = state ? "zoomroom.share_content_start" : "zoomroom.share_content_stop"
    body = JSON.parse({
      "method" => method,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:sharing_content] = state
    logger.debug { "Content sharing #{state ? "started" : "stopped"}" }
    nil
  end

  def stop_share_content(room_id : String? = nil)
    share_content(false, room_id)
  end

  # Volume control
  def set_volume(level : Int32, room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    # Ensure volume is within valid range (0-100)
    level = level.clamp(0, 100)

    body = JSON.parse({
      "method" => "zoomroom.volume_level",
      "params" => {
        "level" => level,
      },
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:volume] = level
    logger.debug { "Volume set to #{level}" }
    nil
  end

  # Room check-in/out
  def check_in(
    calendar_id : String,
    event_id : String,
    resource_email : String,
    change_key : String? = nil,
    room_id : String? = nil,
  )
    room_id ||= @default_room_id || raise "No room_id provided"

    params = {
      "calendar_id"    => calendar_id,
      "event_id"       => event_id,
      "resource_email" => resource_email,
    }
    params["change_key"] = change_key if change_key

    body = JSON.parse({
      "method" => "zoomroom.check_in",
      "params" => params,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:checked_in] = true
    logger.info { "Checked in to room" }
    nil
  end

  def check_out(
    calendar_id : String,
    event_id : String,
    resource_email : String,
    change_key : String? = nil,
    room_id : String? = nil,
  )
    room_id ||= @default_room_id || raise "No room_id provided"

    params = {
      "calendar_id"    => calendar_id,
      "event_id"       => event_id,
      "resource_email" => resource_email,
    }
    params["change_key"] = change_key if change_key

    body = JSON.parse({
      "method" => "zoomroom.check_out",
      "params" => params,
    }.to_json)

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    self[:checked_in] = false
    logger.info { "Checked out of room" }
    nil
  end

  # List Zoom Room locations
  def list_locations(
    parent_location_id : String? = nil,
    type : String? = nil,
    page_size : Int32 = 30,
    next_page_token : String? = nil,
  )
    params = {} of String => String
    params["parent_location_id"] = parent_location_id if parent_location_id
    params["type"] = type if type
    params["page_size"] = page_size.to_s
    params["next_page_token"] = next_page_token if next_page_token

    result = api_request("GET", "/rooms/locations", params: params)
    self[:locations] = result.try(&.["locations"])
    result
  end

  # List calendar events
  def list_calendar_events(
    calendar_id : String,
    from : String? = nil,
    to : String? = nil,
    page_size : Int32 = 30,
    next_page_token : String? = nil,
  )
    params = {} of String => String
    params["from"] = from if from
    params["to"] = to if to
    params["page_size"] = page_size.to_s
    params["next_page_token"] = next_page_token if next_page_token

    result = api_request("GET", "/calendars/#{calendar_id}/events", params: params)
    self[:calendar_events] = result.try(&.["events"])
    result
  end
end
