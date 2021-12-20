require "placeos-driver"
require "placeos-driver/interface/muteable"

# Documentation: https://aca.im/driver_docs/Shure/MXA910%20command%20strings.pdf

class Shure::Microphone::MXA < PlaceOS::Driver
  include Interface::AudioMuteable

  tcp_port 2202
  descriptive_name "Shure Ceiling Array Microphone"
  generic_name :CeilingMic

  default_settings({
    send_meter_levels: false,
  })

  def connected
    transport.tokenizer = Tokenizer.new(" >")

    schedule.every(60.seconds) do
      logger.debug { "-- Polling Mics" }
      do_poll
    end

    query_all
    set_meter_rate(0) if setting?(Bool, :send_meter_levels) != true
  end

  def disconnected
    schedule.clear
  end

  def query_all
    do_send "GET 0 ALL"
  end

  def query_device_id
    do_send "GET DEVICE_ID", name: :device_id
  end

  def query_firmware
    do_send "GET FW_VER", name: :firmware
  end

  # rate in milliseconds
  def set_meter_rate(rate : Int32)
    raise "rate must be a number greater than 100, was #{rate}" unless rate == 0 || rate >= 100
    do_send "SET METER_RATE", rate.to_s, name: :meter_rate
  end

  # Mute commands
  def query_mute
    do_send "GET DEVICE_AUDIO_MUTE"
  end

  def mute(state : Bool = true)
    val = state ? "ON" : "OFF"
    do_send "SET DEVICE_AUDIO_MUTE", val, name: :mute
  end

  def unmute
    mute false
  end

  # part of the mutable interface
  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    mute(state)
  end

  # Preset commands
  def query_preset
    do_send "GET PRESET"
  end

  def preset(number : Int32)
    raise "must be a number between 1-10, was #{number}" unless number.in?(1..10)
    do_send "SET PRESET", number.to_s, name: :preset
  end

  # flash the LED for 30 seconds
  def flash
    do_send "SET FLASH ON"
  end

  enum Colour
    RED
    GREEN
    BLUE
    PINK
    PURPLE
    YELLOW
    ORANGE
    WHITE
  end

  # LED Setup
  def query_led_state
    do_send "GET DEV_LED_IN_STATE"
  end

  def led(on : Bool = true)
    led_state_muted on
    led_state_unmuted on
  end

  def query_led_colour_muted
    do_send "GET LED_COLOR_MUTED"
  end

  # Supported colours: :RED, :GREEN, :BLUE, :PINK, :PURPLE, :YELLOW, :ORANGE, :WHITE
  def led_colour_muted(colour : Colour)
    do_send "SET LED_COLOR_MUTED", colour.to_s.upcase, name: :muted_color
  end

  def query_led_colour_unmuted
    do_send "GET LED_COLOR_UNMUTED"
  end

  def led_colour_unmuted(colour : Colour)
    do_send "SET LED_COLOR_UNMUTED", colour.to_s.upcase, name: :unmuted_color
  end

  def query_led_state_unmuted
    do_send "GET LED_STATE_UNMUTED"
  end

  def led_state_unmuted(on : Bool = true)
    state = on ? "ON" : "OFF"
    do_send "SET LED_STATE_UNMUTED", state
  end

  def query_led_state_muted
    do_send "GET LED_STATE_MUTED"
  end

  def led_state_muted(on : Bool = true)
    state = on ? "ON" : "OFF"
    do_send "SET LED_STATE_MUTED", state
  end

  def received(bytes, task)
    data = String.new(bytes)
    logger.debug { "-- received: #{data}" }

    # Convert { some data here } to " some data here " and remove control chars
    data = data.split("< ", 2)[1].gsub(/[\{\}]/, '"').rchop(" >")

    # Then use shellsplit to capture the parts and remove whitespace
    resp = shellsplit(data).map(&.strip)

    # We want to ignore sample responses
    if resp[0] == "SAMPLE"
      resp[1..-1].each_with_index do |level, index|
        self["output#{index + 1}"] = level.to_i
      end
      return
    end

    return task.try &.abort if resp[1] == "ERR"

    # Check if the first value is a number - channel level details
    if resp[1] =~ /^[0-9]+$/
      chann = resp[1]
      param = resp[2].try &.downcase
      value = resp[3].try &.downcase

      self["#{param}_#{chann}"] = value
      return task.try &.success
    end

    # Global value details
    param = resp[1].downcase
    value = resp[2]

    case param
    when "device_audio_mute"     then self[:muted] = value == "ON"
    when "dev_led_state_muted"   then self[:led_muted] = value == "ON"
    when "dev_led_state_unmuted" then self[:led_unmuted] = value == "ON"
    else
      self[param] = case value
                    when "ON"  ; true
                    when "OFF" ; false
                    when .to_i?; value.to_i
                    else
                      value
                    end
    end

    task.try &.success
  end

  def do_poll
    query_device_id
  end

  protected def do_send(*command, **options)
    cmd = "< #{command.join(' ')} >"
    logger.debug { "-- sending: #{cmd}" }
    send(cmd, **options)
  end

  # Quick dirty port of https://github.com/ruby/ruby/blob/master/lib/shellwords.rb
  protected def shellsplit(line : String) : Array(String)
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
