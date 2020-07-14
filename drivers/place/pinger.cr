module Place; end

require "pinger"

class Place::Pinger < PlaceOS::Driver
  descriptive_name "Device Pinger"
  generic_name :Ping

  # Discard port
  udp_port 9
  description %(periodically pings a device)

  default_settings({
    ping_every: 60
  })

  def on_load
    on_update
  end

  def on_update
    # Use quite a large random value to spread load
    period = setting?(Int32, :ping_every) || 60
    period = period * 1000 + rand(1000)

    schedule.clear
    schedule.every(period.milliseconds) { ping }
  end

  def ping
    hostname = config.ip.not_nil!
    pinger = ::Pinger.new(hostname, count: 3)
    pinger.ping

    pingable = pinger.pingable
    if !pingable
      self[:last_error] = pinger.exception || pinger.warning || "unknown error"
    end

    set_connected_state pingable
    self[:pingable] = pingable
  end
end
