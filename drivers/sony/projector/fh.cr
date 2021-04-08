require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

# Documentation: https://drive.google.com/a/room.tools/file/d/1C0gAWNOtkbrHFyky_9LfLCkPoMcYU9lO/view?usp=sharing

class Sony::Projector::Fh < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  descriptive_name "Sony Projector FH Series"
  generic_name :Display

  def on_load
    transport.tokenizer = Tokenizer.new("\r\n")
  end

  def connected
    schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    set("power", state ? "on" : "off").get
    self[:power] = state
  end

  def power?
    get("power_status")
    !!self[:power]?.try(&.as_bool)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    set("blank", state ? "on" : "off").get
    self[:mute] = state
  end

  def mute?
    get("blank").get
    self[:mute].as_bool
  end

  INPUTS = {
    "hdmi"    => "hdmi1", # Input C
    "dvi"     => "dvi1",  # Input B
    "video"   => "video1",
    "svideo"  => "svideo1",
    "rgb"     => "rgb1",     # Input A
    "hdbaset" => "hdbaset1", # Input D
    "inputa"  => "input_a",
    "inputb"  => "input_b",
    "inputc"  => "input_c",
    "inputd"  => "input_d",
    "inpute"  => "input_e",
  }
  INPUTS.merge!(INPUTS.invert)

  def switch_to(input : String)
    set("input", INPUTS[input]).get
    self[:input] = input
  end

  def input?
    get("input").get
    self[:input].as_s
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
  end

  def received(response, task)
    process_response(response, task)
  end

  private def process_response(response, task, path = nil)
    response = String.new(response)
    logger.debug { "Sony proj sent: #{response}" }
    data = shellsplit(response.strip.downcase)

    return task.try &.success if data[0] == "ok"
    return task.try &.abort if data[0] == "err_cmd"

    case path
    when "power_status"
      self[:power] = data[0] == "on"
    when "blank"
      self[:mute] = data[0] == "on"
    when "input"
      self[:input] = INPUTS[data[0]]
    end
    task.try &.success
  end

  private def get(path, **options)
    cmd = "#{path} ?\r\n"
    logger.debug { "Sony projector FH requesting: #{cmd}" }
    send(cmd, **options) { |data, task| process_response(data, task, path) }
  end

  private def set(path, arg, **options)
    cmd = "#{path} \"#{arg}\"\r\n"
    logger.debug { "Sony projector FH sending: #{cmd}" }
    send(cmd, **options) { |data, task| process_response(data, task, path) }
  end

  # Quick dirty port of https://github.com/ruby/ruby/blob/master/lib/shellwords.rb
  private def shellsplit(line : String) : Array(String)
    words = [] of String
    field = ""
    pattern = /\G\s*(?>([^\s\\\'\"]+)|'([^\']*)'|"((?:[^\"\\]|\\.)*)"|(\\.?)|(\S))(\s|\z)?/m
    line.scan(pattern) do |match|
      _, word, sq, dq, esc, garbage, sep = match.to_a
      raise ArgumentError.new("Unmatched quote: #{line.inspect}") if garbage
      field += (word || sq || dq.try(&.gsub(/\\([$`"\\\n])/, "\\1")) || esc.not_nil!.gsub(/\\(.)/, "\\1"))
      if sep
        words << field
        field = ""
      end
    end
    words
  end
end
