require "placeos-driver"
require "base64"
require "json"
require "jwt"

# Documentation: https://developers.zoom.us/docs/api/rooms/

class Zoom::RoomsApi < PlaceOS::Driver
  descriptive_name "Zoom Rooms Cloud REST API"
  generic_name :ZoomAPI
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

    sdk_client_id:     "your_client_id",
    sdk_client_secret: "your_client_secret",
  })

  def on_update
    # Read settings
    @account_id = setting(String, :account_id)
    @client_id = setting(String, :client_id)
    @client_secret = setting(String, :client_secret)
    @sdk_client_id = setting?(String, :sdk_client_id) || @client_id
    @sdk_client_secret = setting?(String, :sdk_client_secret) || @client_secret
  end

  getter client_id : String = ""
  getter sdk_client_id : String = ""

  @auth_token : AccessToken? = nil
  @account_id : String = ""
  @client_secret : String = ""
  @sdk_client_secret : String = ""

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
    auth_token = @auth_token
    if auth_token.nil? || (auth_token && auth_token.expired?)
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
        @auth_token = auth_token = AccessToken.from_json(response.body)

        # TODO:: fix this, needs to be against the transport
        http_uri_override = auth_token.api_url
      else
        logger.error { "Failed to authenticate: #{response.status_code}\n#{response.body}" }
        raise "Authentication failed: #{response.status_code}, response: #{response.body}"
      end
    end
    @auth_token.as(AccessToken).access_token
  end

  enum Role
    Participant = 0
    Host
  end

  @[Security(Level::Administrator)]
  def generate_jwt(meeting_number : String, issued_at : Int64? = nil, expires_at : Int64? = nil, role : Role? = nil)
    iat = issued_at || 2.minutes.ago.to_unix     # issued at time, 2 minutes earlier to avoid clock skew
    exp = expires_at || 2.hours.from_now.to_unix # token expires after 2 hours

    # https://developers.zoom.us/docs/meeting-sdk/auth/
    payload = {
      "appKey" => @sdk_client_id,
      # "sdkKey"   => @client_id, # no longer needed
      "mn"       => meeting_number,
      "role"     => (role || Role::Participant).to_i,
      "iat"      => iat,
      "exp"      => exp,
      "tokenExp" => exp,
    }

    JWT.encode(payload, @sdk_client_secret, JWT::Algorithm::HS256)
  end

  private def api_request(method : String, resource : String, body = nil, params : Hash(String, String)? = nil)
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
    params = {
      "status"          => status,
      "type"            => type,
      "location_id"     => location_id,
      "page_size"       => page_size.to_s,
      "next_page_token" => next_page_token,
    }.compact

    api_request("GET", "/rooms", params: params)
  end

  # Get specific room details
  # the user_id in this response can be used to get the upcoming meetings
  # https://developers.zoom.us/docs/api/rooms/#tag/zoom-rooms/GET/rooms/{roomId}
  def get_room(room_id : String)
    api_request("GET", "/rooms/#{room_id}")
  end

  enum MeetingType
    Scheduled        # All valid previous (unexpired) meetings, live meetings, and upcoming scheduled meetings.
    Live             # All the ongoing meetings
    Upcoming         # All upcoming meetings, including live meetings.
    UpcomingMeetings # All upcoming meetings, including live meetings.
    PreviousMeetings # All the previous meetings.
  end

  # list the meetings in the room
  # https://developers.zoom.us/docs/api/meetings/#tag/meetings/get/users/{userId}/meetings
  def list_user_meetings(room_user_id : String, type : MeetingType = MeetingType::Scheduled)
    params = {
      "type" => type.to_s.underscore,
    }
    api_request("GET", "/users/#{room_user_id}/meetings", params: params)
  end

  # List calendar events
  def list_calendar_events(
    calendar_id : String,
    from : String? = nil,
    to : String? = nil,
    page_size : Int32 = 30,
    next_page_token : String? = nil,
  )
    api_request("GET", "/calendars/#{calendar_id}/events", params: {
      "from"            => from,
      "to"              => to,
      "page_size"       => page_size.to_s,
      "next_page_token" => next_page_token,
    }.compact)
  end

  # List Zoom Room locations
  def list_locations(
    parent_location_id : String? = nil,
    type : String? = nil,
    page_size : Int32 = 30,
    next_page_token : String? = nil,
  )
    params = {
      "parent_location_id" => parent_location_id,
      "type"               => type,
      "page_size"          => page_size.to_s,
      "next_page_token"    => next_page_token,
    }.compact

    api_request("GET", "/rooms/locations", params: params)
  end

  # List Zoom Room devices
  def list_devices(room_id : String)
    api_request("GET", "/rooms/#{room_id}/devices")
  end

  # Get device information
  def get_device_info(room_id : String)
    api_request("GET", "/rooms/#{room_id}/device_profiles")
  end

  # List device profiles
  def list_device_profiles(room_id : String)
    api_request("GET", "/rooms/#{room_id}/device_profiles")
  end

  # Get Zoom Room sensor data
  def get_sensor_data(room_id : String, from : String? = nil, to : String? = nil)
    api_request("GET", "/rooms/#{room_id}/sensor_data", params: {
      "from" => from,
      "to"   => to,
    }.compact)
  end

  # Get Zoom Room settings
  def get_room_settings(room_id : String)
    api_request("GET", "/rooms/#{room_id}/settings")
  end

  # ==============================
  # in-meeting controls
  # ==============================

  enum Recording
    Start
    Stop
    Pause
    Resume
  end

  def meeting_recording(meeting_id : String | Int64, command : Recording) : Nil
    body = {
      method: "recording.#{command.to_s.downcase}",
    }
    api_request("PATCH", "/live_meetings/#{meeting_id}/events", body: body)
    logger.debug { "Updated recording state: #{command}" }
  end

  def meeting_call_phone(
    meeting_id : String | Int64,
    invitee_name : String,
    phone_number : String,
    require_greeting : Bool = true,
    require_pressing_one : Bool = true,
  ) : Nil
    body = {
      method: "participant.invite.callout",
      params: {
        invitee_name:   invitee_name,
        phone_number:   phone_number,
        invite_options: {
          require_greeting:     require_greeting,
          require_pressing_one: require_pressing_one,
        },
      },
    }

    api_request("PATCH", "/live_meetings/#{meeting_id}/events", body: body)
    logger.debug { "Calling: #{invitee_name} => #{phone_number}" }
  end

  def meeting_invite_contacts(meeting_id : String | Int64, email : String | Array(String)) : Nil
    email = email.is_a?(String) ? [email] : email
    emails = email.map { |address| {email: address} }
    body = {
      method: "participant.invite",
      params: {
        contacts: emails,
      },
    }

    api_request("PATCH", "/live_meetings/#{meeting_id}/events", body: body)
    logger.debug { "Inviting: #{email}" }
  end

  def meeting_waiting_room(meeting_id : String | Int64, title : String, description : String) : Nil
    body = {
      method: "waiting_room.update",
      params: {
        waiting_room_title:       title,
        waiting_room_description: description,
      },
    }

    api_request("PATCH", "/live_meetings/#{meeting_id}/events", body: body)
    logger.debug { "Waiting room update: #{title}\n#{description}" }
  end

  # ==============================
  # Zoom Room Controls
  # ==============================

  # Room Controls - Mute/Unmute microphone
  def mute(room_id : String, state : Bool = true) : Nil
    method = state ? "zoomroom.mute" : "zoomroom.unmute"
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: method})
    logger.debug { "Microphone #{state ? "muted" : "unmuted"} in #{room_id}" }
  end

  def unmute(room_id : String)
    mute(room_id, false)
  end

  def meeting_accept(room_id : String) : Nil
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: "zoomroom.meeting_accept"})
    logger.debug { "Zoom Room meeting accept in #{room_id}" }
  end

  def meeting_decline(room_id : String) : Nil
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: "zoomroom.meeting_decline"})
    logger.debug { "Zoom Room meeting decline in #{room_id}" }
  end

  # Video mute/unmute
  def video_mute(room_id : String, state : Bool = true) : Nil
    method = state ? "zoomroom.video_mute" : "zoomroom.video_unmute"
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: method})
    logger.debug { "Video #{state ? "muted" : "unmuted"} in #{room_id}" }
  end

  def video_unmute(room_id : String)
    video_mute(room_id, false)
  end

  # Restart Zoom Room
  def restart_room(room_id : String) : Nil
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: "zoomroom.restart"})
    logger.info { "Zoom Room restart initiated in #{room_id}" }
  end

  # Meeting controls
  def meeting_leave(room_id : String) : Nil
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: "zoomroom.meeting_leave"})
    logger.info { "Left meeting in #{room_id}" }
  end

  def meeting_end(room_id : String) : Nil
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: "zoomroom.meeting_end"})
    logger.info { "Ended meeting in #{room_id}" }
  end

  def meeting_schedule(room_id : String, meeting_topic : String, start_time : Int64, duration_min : Int32, passcode : String? = nil, join_before_host : Bool = true) : Nil
    body = {
      method: "zoomroom.meeting_schedule",
      params: {
        "passcode"      => passcode,
        "meeting_topic" => meeting_topic,
        "start_time"    => Time.unix(start_time).to_rfc3339,
        "duration"      => duration_min,
        "settings"      => {
          "join_before_host" => join_before_host,
        },
      }.compact,
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.info { "Meeting #{meeting_topic} scheduled in #{room_id}" }
  end

  def meeting_join_thirdparty(room_id : String, join_url : String) : Nil
    if join_url =~ /https:\/\/(?:[\w.-]*teams\.microsoft\.com|teams\.live\.com)\/[^\s>"]+/i
      meeting_source_type = "MS_TEAMS"
    elsif join_url =~ /https:\/\/meet\.google\.com\/[^\s>"]+/i
      meeting_source_type = "GOOGLE_MEET"
    else
      raise "only supports Google Meet or MS Teams"
    end

    body = {
      method: "zoomroom.thirdparty_meeting_join",
      params: {
        "join_type"           => "url",
        "meeting_source_type" => meeting_source_type,
        "join_url"            => join_url,
      }.compact,
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.debug { "Joining 3rd party meeting #{join_url} in #{room_id}" }
  end

  def meeting_join(room_id : String, meeting_number : String | Int64, password : String? = nil, host : Bool = false) : Nil
    body = {
      method: "zoomroom.meeting_join",
      params: {
        "meeting_number"      => meeting_number.to_s,
        "password"            => password,
        "force_accept"        => true,
        "make_zoom_room_host" => host,
      }.compact,
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.info { "Joined meeting #{meeting_number} in #{room_id}" }
  end

  # Device switching
  def switch_camera(room_id : String, camera_id : String) : Nil
    body = {
      method: "zoomroom.switch_camera",
      params: {
        cameraId: camera_id,
      },
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.debug { "Switched to camera #{camera_id} in #{room_id}" }
  end

  def switch_microphone(room_id : String, microphone_id : String) : Nil
    body = {
      method: "zoomroom.switch_microphone",
      params: {
        microphoneId: microphone_id,
      },
    }
    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.debug { "Switched to microphone #{microphone_id} in #{room_id}" }
  end

  def switch_speaker(room_id : String, speaker_id : String) : Nil
    body = {
      method: "zoomroom.switch_speaker",
      params: {
        "speakerId" => speaker_id,
      },
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.debug { "Switched to speaker #{speaker_id} in #{room_id}" }
  end

  # Content sharing
  def share_content(room_id : String, state : Bool = true) : Nil
    method = state ? "zoomroom.share_content_start" : "zoomroom.share_content_stop"
    api_request("PATCH", "/rooms/#{room_id}/events", body: {method: method})
    logger.debug { "Content sharing #{state ? "started" : "stopped"} in #{room_id}" }
  end

  def stop_share_content(room_id : String)
    share_content(room_id, false)
  end

  # Volume control
  def set_volume(room_id : String, level : Int32) : Int32
    # Ensure volume is within valid range (0-100)
    level = level.clamp(0, 100)

    body = {
      method: "zoomroom.volume_level",
      params: {
        volume_level: level,
      },
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.debug { "Volume set to #{level} in #{room_id}" }
    level
  end

  # Room check-in/out
  def check_in(
    room_id : String,
    # The unique identifier of the calendar event associated with the Zoom Room.
    event_id : String,
    # This field is only required for Microsoft Exchange / Office 365 Calendar
    resource_email : String? = nil,
    # This field is required only for Microsoft Exchange or Office 365 calendar
    change_key : String? = nil,
    # only required if using Google Calendar
    calendar_id : String? = nil,
  ) : Nil
    params = {
      "calendar_id"    => calendar_id,
      "event_id"       => event_id,
      "resource_email" => resource_email,
      "change_key"     => change_key,
    }.compact

    body = {
      method: "zoomroom.check_in",
      params: params,
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.info { "Checked in to room #{room_id}" }
  end

  def check_out(
    room_id : String,
    # The unique identifier of the calendar event associated with the Zoom Room.
    event_id : String,
    # This field is only required for Microsoft Exchange / Office 365 Calendar
    resource_email : String? = nil,
    # This field is required only for Microsoft Exchange or Office 365 calendar
    change_key : String? = nil,
    # only required if using Google Calendar
    calendar_id : String? = nil,
  ) : Nil
    params = {
      "calendar_id"    => calendar_id,
      "event_id"       => event_id,
      "resource_email" => resource_email,
      "change_key"     => change_key,
    }.compact

    body = {
      method: "zoomroom.check_in",
      params: params,
    }

    api_request("PATCH", "/rooms/#{room_id}/events", body: body)
    logger.info { "Checked out of room #{room_id}" }
  end

  # ==============================
end
