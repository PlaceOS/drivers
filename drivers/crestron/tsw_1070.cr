require "placeos-driver"
require "./tsw_models"
require "./cres_next_auth"
require "uri"

# Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/
# Crestron TSW-70/TS-1070 Touch Screen driver using HTTP JSON API
# Note: This device does not support WebSocket interface, uses HTTP polling instead

class Crestron::Tsw1070 < PlaceOS::Driver
  include Crestron::CresNextAuth

  descriptive_name "Crestron TSW-1070 Touch Screen"
  generic_name :TouchPanel
  description <<-DESC
    Crestron TSW-70 series touch screen control via HTTP JSON API.
    Requires firmware 3.002.0034.001 or later.
  DESC

  uri_base "https://192.168.0.5"

  default_settings({
    username: "admin",
    password: "admin",

    http_keep_alive_seconds: 600,
    http_max_requests:       1200,
    base_url:                "https://placeos-nonprod.avit.it.ucla.edu/control-av/#/sys-I-_pptn4a5",
    x_api_key:               "",
  })

  @monitoring : Bool = false
  @lock : Mutex = Mutex.new

  def on_load
    # Re-authenticate every 10 minutes
    schedule.every(10.minutes) { authenticate }

    # Sync device state every hour
    schedule.every(1.hour) { poll_device_info }
  end

  def on_update
    authenticate
  end

  def connected
    if !authenticated?
      # connected is called again by the authenticate function
      spawn { authenticate }
      return
    end

    poll_device_info
    @lock.synchronize do
      if !@monitoring
        spawn { event_monitor }
        @monitoring = true
      end
    end
  end

  # ====== Device Information ======
  # Documentation: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Objects/DeviceInfo.htm

  def poll_device_info
    response = get("/Device/DeviceInfo", concurrent: true)
    raise "unexpected response code: #{response.status_code}" unless response.success?

    payload = JSON.parse(response.body)
    device_info_json = payload["Device"]["DeviceInfo"].to_json

    device_info = Crestron::DeviceInfo.from_json(device_info_json)
    self[:device_info] = device_info

    device_info
  end

  # TODO
  # def poll_third_party_app
  #   response = get("/Device/ThirdPartyApplications")
  #   raise "unexpected response code: #{response.status_code}" unless response.success?

  #   payload = JSON.parse(response.body)
  #   device_app_info = payload.dig("Device", "ThirdPartyApplications")

  #   device_app_info = Crestron::
  # end

  # Long polling for real-time updates
  def event_monitor
    loop do
      break if terminated?
      if authenticated?
        # sleep if long poll failed
        logger.debug { "event monitor: performing long poll" }
        sleep 1.second unless long_poll
      else
        # sleep if not authenticated
        logger.debug { "event monitor: idling as not authenticated" }
        sleep 1.second
      end
    end
  end

  # NOTE:: /Device/Longpoll
  # 200 == check data
  #  when nothing new: {"Device":"Response Timeout"}
  #  when update: {"Device":{...}}
  # 301 == authentication required
  protected def long_poll : Bool
    response = get("/Device/Longpoll")

    # retry after authenticating
    if response.status_code == 301
      authenticate
      response = get("/Device/Longpoll")
    end
    raise "unexpected response code: #{response.status_code}" unless response.success?

    raw_json = response.body
    logger.debug { "long poll sent: #{raw_json}" }
    payload = JSON.parse(raw_json)

    # Check if there's actual device data (not just a timeout response)
    if device_data = payload["Device"]?
      # Skip if it's just a timeout message
      return true if device_data.as_s? == "Response Timeout"

      # Process any device info updates
      if device_info_json = device_data.dig?("DeviceInfo")
        device_info = Crestron::DeviceInfo.from_json(device_info_json.to_json)
        self[:device_info] = device_info
        logger.debug { "Device updated via long poll: #{device_info.name}" }
      end
    end

    true
  rescue timeout : IO::TimeoutError
    logger.debug { "timeout waiting for long poll to complete" }
    false
  rescue error
    logger.warn(exception: error) { "during long polling" }
    false
  end

  # Additional API endpoints can be added here as needed
  # Refer to: https://sdkcon78221.crestron.com/sdk/TSW-70-API/Content/Topics/Home.htm
end
