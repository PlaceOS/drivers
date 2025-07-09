require "placeos-driver"
require "./cres_next_auth"

class Crestron::Series4 < PlaceOS::Driver
  include Crestron::CresNextAuth

  descriptive_name "Crestron Series4 Controller"
  generic_name :AVController

  uri_base "https://192.168.0.5"

  default_settings({
    username: "admin",
    password: "admin",

    http_keep_alive_seconds: 600,
    http_max_requests:       1200,
  })

  getter last_update : Int64 = 0_i64
  getter poll_counter : UInt64 = 0_u64

  @time_zone : Time::Location = Time::Location.load("UTC")

  def on_update
    time_zone = setting?(String, :calendar_time_zone).presence || config.control_system.not_nil!.timezone.presence
    @time_zone = Time::Location.load(time_zone) if time_zone
  end

  def connected
    schedule.every(10.minutes, immediate: true) { authenticate }
    schedule.every(1.hour, immediate: true) { get_device_info }
  end

  def disconnected
    schedule.clear
  end

  def get_device_info : Nil
    response = get("/Device/DeviceInfo/")
    raise "unexpected response code: #{response.status_code}" unless response.success?

    payload = JSON.parse(response.body)
    self[:last_updated] = Time.local(@time_zone)
    self[:info] = payload.dig("Device", "DeviceInfo")
  end
end
