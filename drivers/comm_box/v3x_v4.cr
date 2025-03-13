require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class CommBox::V3X_V4 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    Vga         = 111 # pc in manual
    Dvi         = 221
    Hdmi        = 211
    Hdmi2       = 212
    Hdmi3       = 213
    Hdmi4       = 214
    DisplayPort = 231
    Dtv         = 250
    Media       = 310
  end
  include Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 4660
  descriptive_name "CommBox V3, V3X and V4 Display "
  generic_name :Display

  DELIMITER = "\r"

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
  end

  def connected
    schedule.every(50.seconds) { power? }
  end

  def disconnected
    schedule.clear
  end

  def switch_to(input : Input, **options)
    send "!200INPT #{input.value}\r", name: "input"
  end

  def volume(value : Int32 | Float64, **options)
    data = value.to_f.clamp(0.0, 100.0).round_away.to_i
    send "!200VOLM #{data}\r", name: "volume"
  end

  # Mutes both audio/video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    mute_audio(state) if layer.audio? || layer.audio_video?
  end

  # Emulate audio mute
  def mute_audio(state : Bool = true)
    send "!200MUTE #{state ? 1 : 0}\r", name: "mute"
  end

  def power?
    send "!200POWR ?\r"
  end

  def input?
    send "!200INPT ?\r"
  end

  def volume?
    send "!200VOLM ?\r"
  end

  def toggle_mute
    send "!200MUTE 2\r", name: "toggle_mute"
  end

  def freeze_screen
    send "!200FREZ 1\r", name: "freeze_on"
  end

  def toggle_freeze_screen
    send "!200FREZ 2\r", name: "togge_freeze"
  end

  def freeze_screen?
    send "!200FREZ ?\r"
  end

  def power(state : Bool)
    if state
      send "!200POWR 1\r", name: "power"
    else
      send "!200POWR 0\r", name: "power"
    end
  end

  def age_mode(state : Bool)
    if state
      send "!200AGEM 1\r", name: "age_mode"
    else
      send "!200AGEMR 0\r", name: "age_mode"
    end
  end

  def toggle_age_mode
    send "!200AGEM 2\r", name: "age_mode"
  end

  def age_mode?
    send "!200AGEM ?\r"
  end

  @[Security(Level::Administrator)]
  def custom_send(raw : String)
    send "#{raw}\r"
  end

  # Command is in format of header, version, ID, command name, separator, parameters, terminator
  # A common received function for handling responses
  def received(data, task)
    data = String.new(data).strip
    logger.debug { "received data: #{data}" }

    cmd, value = data.split("=", 2)
    return task.try &.abort if error_check(cmd, value)

    case cmd
    when "!201VOLM"
      self[:volume_level] = value.to_i
    when "!201MUTE"
      self[:mute] = value == "1"
    when "!201INPT"
      self[:input] = Input.from_value(value.to_i)
    when "!201POWR"
      self[:power] = value == "1"
    when "!201FREZ"
      self[:freeze] = value
    when "!201AGEM"
      self[:age_mode] = value
    else
      logger.debug { "Unknown Output: #{cmd} with value #{value}" }
    end

    task.try &.success
  end

  def error_check(data : String, value : String) : Bool
    return false unless value.starts_with?("ERR")

    case value
    when "ERR1"
      logger.warn { "ERR1 - The command is invalid" }
      true
    when "ERR2"
      logger.warn { "ERR2 - The parameter is out of range or not supported." }
      true
    when "ERR3"
      logger.warn { "ERR3 - The command is unavailable at this time." }
      true
    when "ERR4"
      logger.warn { "ERR4 - General failure - all other errors." }
      true
    else
      logger.warn { "Unknown Error : #{value}" }
      true
    end
  end
end
