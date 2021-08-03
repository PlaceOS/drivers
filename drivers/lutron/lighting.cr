require "placeos-driver"

# Documentation: https://aca.im/driver_docs/Lutron/lutron-lighting.pdf

# Device defaults
# Login #1: nwk
# Login #2: nwk2

# Login: lutron
# Password: integration

class Lutron::Lighting < PlaceOS::Driver
  # Discovery Information
  tcp_port 23
  descriptive_name "Lutron Lighting Gateway"
  generic_name :Lighting

  def on_load
    # Communication settings
    queue.wait = false
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new("\r\n")

    on_update
  end

  @trigger_type : String = "area"
  @login : String = "nwk"

  def on_update
    @login = setting?(String, :login) || "nwk"
    @trigger_type = setting?(String, :trigger) || "area"
  end

  def connected
    send "#{@login}\r\n", priority: 9999

    schedule.every(40.seconds) do
      logger.debug { "-- Polling Lutron" }
      scene? 1
    end
  end

  def disconnected
    schedule.clear
  end

  def restart
    send_cmd "RESET", 0
  end

  # on or off
  def lighting(device : Int32, state : Bool, action : Int32 = 1)
    level = state ? 100 : 0
    light_level(device, level)
  end

  # ===============
  # OUTPUT COMMANDS
  # ===============

  # dimmers, CCOs, or other devices in a system that have a controllable output
  def level(
    device : Int32,
    level : Int32,
    rate : Int32 = 1000,
    component : String = "output"
  )
    level = level.clamp(0, 100)
    seconds = rate / 1000
    min = seconds / 60
    seconds -= min * 60
    time = "#{min.to_s.rjust(2, '0')}:#{seconds.to_s.rjust(2, '0')}"
    send_cmd component.upcase, device, 1, level, time
  end

  def blinds(device : String, action : String, component : String = "shadegrp")
    case action.downcase
    when "raise", "up"
      send_cmd component.upcase, device, 3
    when "lower", "down"
      send_cmd component.upcase, device, 2
    when "stop"
      send_cmd component.upcase, device, 4
    end
  end

  # =============
  # AREA COMMANDS
  # =============
  def scene(area : Int32, scene : Int32, component : String = "area")
    send_cmd(component.upcase, area, 6, scene).get
    scene?(area, component)
  end

  def scene?(area : Int32, component : String = "area")
    send_query component.upcase, area, 6
  end

  def occupancy?(area : Int32)
    send_query "AREA", area, 8
  end

  def daylight_mode?(area : Int32)
    send_query "AREA", area, 7
  end

  def daylight(area : Int32, mode : Bool)
    val = mode ? 1 : 2
    send_cmd "AREA", area, 7, val
  end

  # ===============
  # DEVICE COMMANDS
  # ===============
  def button_press(area : Int32, button : Int32)
    send_cmd "DEVICE", area, button, 3
  end

  def led(area : Int32, device : Int32, state : Int32 | Bool)
    val = if state.is_a?(Int32)
            state
          else
            state ? 1 : 0
          end

    send_cmd "DEVICE", area, device, 9, val
  end

  def led?(area : Int32, device : Int32)
    send_query "DEVICE", area, device, 9
  end

  # =============
  # COMPATIBILITY
  # =============
  def trigger(area : Int32, scene : Int32)
    scene(area, scene, @trigger_type)
  end

  def light_level(area : Int32, level : Int32, component : String? = nil, fade : Int32 = 1000)
    if component
      level(area, level, fade, component)
    else
      level(area, level, fade, "area")
    end
  end

  Errors = {
    "1" => "Parameter count mismatch",
    "2" => "Object does not exist",
    "3" => "Invalid action number",
    "4" => "Parameter data out of range",
    "5" => "Parameter data malformed",
    "6" => "Unsupported Command",
  }

  Occupancy = {
    "1" => "unknown",
    "2" => "inactive",
    "3" => "occupied",
    "4" => "unoccupied",
  }

  def received(data, task)
    data = String.new(data)
    logger.debug { "Lutron sent: #{data}" }

    parts = data.split(",")
    component = parts[0][1..-1].downcase

    case component
    when "area", "output", "shadegrp"
      area = parts[1]
      action = parts[2].to_i
      param = parts[3]

      case action
      when 1 # level
        self["#{component}#{area}_level"] = param.to_f
      when 6 # Scene
        self["#{component}#{area}"] = param.to_i
      when 7
        self["#{component}#{area}_daylight"] = param == "1"
      when 8
        self["#{component}#{area}_occupied"] = Occupancy[param]
      end
    when "device"
      area = parts[1]
      device = parts[2]
      action = parts[3].to_i

      case action
      when 7 # Scene
        self["device#{area}_#{device}"] = parts[4].to_i
      when 9 # LED state
        self["device#{area}_#{device}_led"] = parts[4].to_i
      end
    when "error"
      error = "error #{parts[1]}: #{Errors[parts[1]]}"
      logger.warn { error }
      return task.try &.abort(error)
    end

    task.try &.success
  end

  protected def send_cmd(*command)
    cmd = "##{command.join(",")}"
    logger.debug { "Requesting: #{cmd}" }
    send("#{cmd}\r\n")
  end

  protected def send_query(*command)
    cmd = "?#{command.join(",")}"
    logger.debug { "Querying: #{cmd}" }
    send("#{cmd}\r\n")
  end
end
