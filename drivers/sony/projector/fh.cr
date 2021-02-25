require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

# Documentation: https://drive.google.com/a/room.tools/file/d/1C0gAWNOtkbrHFyky_9LfLCkPoMcYU9lO/view?usp=sharing

class Sony::Projector::Fh < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  descriptive_name "Sony Projector FH Series"
  generic_name :Display

  def connected
    schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    set("power", state ? "on" : "off").get
    power?
  end

  def power?
    get("power_status").get
    self[:power]?.try(&.as_bool)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    set("blank", state ? "on" : "off").get
    mute?
  end

  def mute?
    get("blank")
    self[:mute].as_bool
  end

  INPUTS = {
    "hdmi" => "hdmi1",       #Input C
    "dvi" => "dvi1",        #Input B
    "video" => "video1",
    "svideo" => "svideo1",
    "rgb" => "rgb1",        #Input A
    "hdbaset" => "hdbaset1",    #Input D
    "inputa" => "input_a",
    "inputb" => "input_b",
    "inputc" => "input_c",
    "inputd" => "input_d",
    "inpute" => "input_e"
  }
  INPUTS.merge!(INPUTS.invert)

  def switch_to(input : String)
    set("input", INPUTS[input]).get
    input?
  end

  def input?
    get("input").get
    self[:input].as_s
  end

  def lamp_time?
    get("timer")
  end

  {% for name in ["contrast", "brightness", "color", "hue", "sharpness"] %}
    def {{name.id}}?
      get({{name.id.stringify}})
    end

    def {{name.id}}(val : Int32)
      set({{name.id.stringify}}, val.clamp(0, 100))
    end
  {% end %}

  private def do_poll
    return unless power?
    input?
    mute?
    lamp_time?
  end

  def received(data, task)
    task.try &.success
  end

  private def get(path, **options)
    cmd = "#{path} ?\r\n"
    logger.debug { "Sony projector FH requesting: #{cmd}" }
    send(cmd, **options)
  end

  private def set(path, arg, **options)
    cmd = "#{path} \"#{arg}\"\r\n"
    logger.debug { "Sony projector FH sending: #{cmd}" }
    send(cmd, **options)
  end
end
