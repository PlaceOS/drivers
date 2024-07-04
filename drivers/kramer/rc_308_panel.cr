require "placeos-driver"

class Kramer::RC308Panel < PlaceOS::Driver
  # Discovery Information
  tcp_port 50000
  descriptive_name "Kramer RC-308 Key Pad"
  generic_name :KeyPad

  default_settings({
    button_count:  8,
    default_light: {
      red:   255,
      green: 0,
      blue:  0,
    },
  })

  record(DefaultLight,
    red : UInt8,
    green : UInt8,
    blue : UInt8
  ) do
    include JSON::Serializable
  end

  @default : DefaultLight = DefaultLight.new(255_u8, 0_u8, 0_u8)
  @button_count : UInt8 = 8_u8

  # \r\n 0D0A
  DELIMITER = "\r\n"

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
    on_update

    (0..@button_count).each do |idx|
      self["button#{idx}_state"] = ButtonAction::Released
    end
  end

  def on_update
    @default = setting?(DefaultLight, :default_light) || DefaultLight.new(255_u8, 0_u8, 0_u8)
    @button_count = setting?(UInt8, :button_count) || 8_u8
  end

  def connected
    schedule.clear
    schedule.every(1.minute, true) { query_state }
  end

  def disconnected
    schedule.clear
  end

  def query_state
    (1_u8..@button_count).each do |idx|
      button_state? idx
    end
  end

  def button_state(index : UInt8, light : Bool, red : UInt8? = nil, green : UInt8? = nil, blue : UInt8? = nil)
    data = "#RGB #{index},#{red || @default.red},#{green || @default.green},#{blue || @default.blue},#{light ? '1' : '0'}\r"
    send data, name: "button#{index}"
  end

  def button_state?(index : UInt8, priority : Int32 = 0)
    send "#RGB? #{index}\r", priority: priority
  end

  enum ButtonAction
    Pressed
    Released
    HeldDown

    def self.check(type : String)
      case type.downcase
      when "p"
        ButtonAction::Pressed
      when "r"
        ButtonAction::Released
      when "h"
        ButtonAction::HeldDown
      else
        raise "unknown button action type: #{type}"
      end
    end
  end

  def received(data, task)
    # Remove the delimiter
    data = String.new(data).strip
    logger.debug { "Kramer sent: #{data.inspect}" }

    # error feedback: ~01@ ERR 002\x0D\x0A
    # Button press feedback: ~01@BTN 1,1,p\x0D\x0A
    # Light query response: ~01@RGB 6,64,64,64,0\x0D\x0A

    # check we're getting some button feedback
    parts = data.split('@', 2)[1].strip.split(' ')
    component = parts[0].upcase
    details = parts[1]
    success = parts[2]?

    case component
    when "BTN"
      light_on, button_index, button_action = details.split(',')
      self["button#{button_index}_light"] = light_on == "1"
      self["button#{button_index}_state"] = ButtonAction.check(button_action)
    when "RGB"
      button_index, red, green, blue, light_on = details.split(',')
      self["button#{button_index}_rgb"] = {red.to_u8, green.to_u8, blue.to_u8}
      self["button#{button_index}_light"] = light_on == "1"
    when "ERR"
      logger.warn { "request failed with error code: #{details}" }
      return task.try &.abort("error code: #{details}")
    else
      logger.warn { "unknown button component #{component}" }
      return
    end

    if task
      if task.name
        task.success if success
      else
        task.success
      end
    end
  end
end
