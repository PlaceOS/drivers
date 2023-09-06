require "placeos-driver"

# Ideally, this driver should be made compatible with these interfaces in the future
# require "placeos-driver/interface/moveable"
# require "placeos-driver/interface/stoppable"

class GlobalCache::ProjectorScreen < PlaceOS::Driver
  # include Interface::Moveable
  # include Interface::Stoppable

  # Discovery Information
  generic_name :Screen
  descriptive_name "Projector Screen via Global Cache Relays"

  default_settings({
    globalcache_module:       "DigitalIO_1",
    globalcache_relay_method: "pulse",
    # OR globalcache_relay_method: "hold"
    # To Do: support "hold" including determine better Settings format
    globalcache_relay_index_down:         0,
    globalcache_relay_index_up:           1,
    globalcache_relay_pulse_milliseconds: 1000,
  })

  @globalcache_module : String = "DigitalIO_1"
  @relay_index_down : Int32 = 0
  @relay_index_up : Int32 = 1
  @relay_method : String = "pulse"
  @relay_pulse_milliseconds : Int32 = 1000

  def on_load
    on_update
  end

  def on_update
    @globalcache_module = setting(String, :globalcache_module) || "DigitalIO_1"
    @globalcache_relay_method = setting(String, :globalcache_relay_method) || "pulse"
    @globalcache_relay_index_down = setting(Int32, :globalcache_relay_index_down) || 0
    @globalcache_relay_index_up = setting(Int32, :globalcache_relay_index_up) || 1
    @globalcache_relay_pulse_milliseconds = setting(Int32, :globalcache_relay_pulse_milliseconds) || 1000
  end

  def up
    case @relay_method
    when "pulse"
      system[@globalcache_module].pulse(@relay_pulse_milliseconds, @relay_index_up)
    when "hold"
      logger.error { "Not yet implemented by this driver." }
    else
      logger.error { "Invalid globalcache_relay_method setting \"#{@relay_method}}\". Must be \"pulse\" or \"hold\" " }
    end
  end

  def down
    case @relay_method
    when "pulse"
      system[@globalcache_module].pulse(@relay_pulse_milliseconds, @relay_index_down)
    when "hold"
      logger.error { "Not yet implemented by this driver." }
    else
      logger.error { "Invalid globalcache_relay_method setting \"#{@relay_method}}\". Must be \"pulse\" or \"hold\" " }
    end
  end
end
