require "placeos-driver"

class Place::Signage::Analytics < PlaceOS::Driver
  descriptive_name "PlaceOS Signage Analytics"
  generic_name :SignageAnalytics
  description %(writes datapoints to influxdb for signage analytics)

  accessor staff_api : StaffAPI_1

  default_settings({
    # time in minutes
    poll_rate: 5,

    # systems to monitor
    org_zone: "zone-XYZ",
  })

  @poll_rate : Time::Span = 5.minutes
  @org_zone : String? = nil

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 5).minutes
    @org_zone = setting?(String, :org_zone)

    subscriptions.clear
    schedule.clear
    schedule.every(@poll_rate) { query_signage_checkin_status }
  end

  # ===================================
  # Monitoring signage checkins
  # ===================================

  struct SignageStatus
    include JSON::Serializable

    getter id : String
    getter signage_last_seen : Int64? = nil
  end

  @running : Bool = false

  def query_signage_checkin_status
    return "already running" if @running

    @running = true
    signs = staff_api.systems(zone_id: @org_zone, signage: true).get_json(Array(SignageStatus))
    not_responding = 5.minutes.ago.to_unix

    running = 0
    online_count = 0

    signs.each do |sign|
      last_seen = sign.signage_last_seen
      next unless last_seen

      running += 1
      online = last_seen > not_responding ? 1 : 0
      online_count += online
      self[sign.id] = online
    end

    percent = running.zero? ? 0.0 : (online_count / running * 100).round(2)
    self[:overview] = {total: running, online: online_count, offline: running - online_count, percent: percent}
  ensure
    @running = false
  end
end
