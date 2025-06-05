require "placeos-driver"
require "json"
require "base64"

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

  uri_base "https://api.zoom.us/v2"

  default_settings({
    base_url:      "https://api.zoom.us/v2",
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
    @base_url = setting(String, :base_url)
    @account_id = setting(String, :account_id)
    @client_id = setting(String, :client_id)
    @client_secret = setting(String, :client_secret)
    @default_room_id = setting?(String, :room_id)

    # Clear token to force re-authentication
    @access_token = nil
    @token_expires_at = nil
  end

  @base_url : String = "https://api.zoom.us/v2"
  @account_id : String = ""
  @client_id : String = ""
  @client_secret : String = ""
  @default_room_id : String? = nil
  @access_token : String? = nil
  @token_expires_at : Time? = nil

  # Authentication
  private def authenticate : String
    # Check if we have a valid token
    if token = @access_token
      if expires_at = @token_expires_at
        return token if expires_at > Time.utc + 5.minutes
      end
    end

    # Request new token using OAuth 2.0
    token_url = "https://zoom.us/oauth/token"

    response = post(
      token_url,
      headers: {
        "Authorization" => "Basic #{Base64.strict_encode("#{@client_id}:#{@client_secret}")}",
        "Content-Type"  => "application/x-www-form-urlencoded",
      },
      body: "grant_type=account_credentials&account_id=#{@account_id}"
    )

    if response.success?
      data = JSON.parse(response.body)
      @access_token = data["access_token"].as_s
      expires_in = data["expires_in"].as_i
      @token_expires_at = Time.utc + expires_in.seconds

      logger.debug { "Successfully authenticated with Zoom API" }
      @access_token.not_nil!
    else
      logger.error { "Failed to authenticate: #{response.status_code} - #{response.body}" }
      raise "Authentication failed: #{response.status_code}"
    end
  end

  private def api_request(method : String, path : String, body : JSON::Any? = nil, params : Hash(String, String)? = nil)
    token = authenticate

    headers = {
      "Authorization" => "Bearer #{token}",
      "Content-Type"  => "application/json",
    }

    url = "#{@base_url}#{path}"

    response = case method.downcase
               when "get"
                 params ? get(url, headers: headers, params: params) : get(url, headers: headers)
               when "post"
                 post(url, headers: headers, body: body.try(&.to_json))
               when "patch"
                 patch(url, headers: headers, body: body.try(&.to_json))
               when "delete"
                 delete(url, headers: headers)
               else
                 raise "Unsupported HTTP method: #{method}"
               end

    unless response.success?
      logger.error { "API request failed: #{method} #{path} - #{response.status_code} - #{response.body}" }
      raise "API request failed: #{response.status_code}"
    end

    response.body.empty? ? nil : JSON.parse(response.body)
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
  def get_room(room_id : String? = nil)
    room_id ||= @default_room_id || raise "No room_id provided"

    result = api_request("GET", "/rooms/#{room_id}")
    self[:room_details] = result
    result
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
