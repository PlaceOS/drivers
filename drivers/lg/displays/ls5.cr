require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Lg::Displays::Ls5 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    Dvi            = 0x70
    Hdmi           = 0xA0
    HdmiDtv        = 0x90
    Hdmi2          = 0xA1
    Hdmi2Dtv       = 0x91
    DisplayPort    = 0xD0
    DisplayPortDtv = 0xC0
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 9761
  descriptive_name "LG WebOS LCD Monitor"
  generic_name :Display
  # This device does not hold the connection open. Must be configured as makebreak
  makebreak!

  default_settings({
    rs232_control: false,
    display_id: 1
  })

  @display_id : Int32 = 0
  @id_num : Int32 = 1
  @rs232 : Bool = false
  @id : String = ""
  @last_broadcast : String? = nil
  @connected : Bool = false

  DELIMITER = 0x78_u8 # 'x'

  def on_load
    # Communication settings
    queue.delay = 150.milliseconds
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
    on_update
  end

  def on_update
    @rs232 = setting(Bool, :rs232_control)
    @id_num = setting(Int32, :display_id)
    @id = @id_num.to_s.rjust(2, '0')
  end

  def connected
    @connected = true
    wake_on_lan
    no_signal_off
    auto_off
    local_button_lock
    pm_mode
    schedule.every(50.seconds, true) do
      do_poll
    end
  end

  def disconnected
    @connected = false
    schedule.clear
  end

  enum Command
    Power           = 0x61 # 'a'
    Input           = 0x62 # 'b'
    AspectRatio     = 0x63 # 'c'
    ScreenMute      = 0x64 # 'd'
    VolumeMute      = 0x65 # 'e'
    Volume          = 0x66 # 'f'
    Contrast        = 0x67 # 'g'
    Brightness      = 0x68 # 'h'
    Sharpness       = 0x6B # 'k'
    AutoOff         = 0x6E # 'n'
    LocalButtonLock = 0x6F # 'o'
    WakeOnLan       = 0x77 # 'w'
    NoSignalOff     = 0x67 # 'g'
    PmMode          = 0x6E # 'n'
  end
  {% for name in Command.constants %}
    @[Security(Level::Administrator)]
    def {{name.id.underscore}}?(priority : Int32 = 0)
      do_send(Command::{{name.id}}, 0xFF, priority: priority, name: {{name.id.underscore.stringify}} + "_status")
    end
  {% end %}

  def power(state : Bool, broadcast : String? = nil)
    if state
      if @rs232
        do_send(Command::Power, 1, name: "power", priority: 99)
      else
        wake(broadcast || @last_broadcast)
      end
    end
    # To power on, unmute the display
    # To power off, mute the display
    mute(!state) if @connected
  end

  def hard_off
    do_send(Command::Power, 0, name: "power", priority: 99, clear_queue: true)
  end

  def switch_to(input : Input, **options)
    do_send(Command::Input, input.value, 'x', name: "input", delay: 2.seconds)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
  mute_video(state) if layer.video? || layer.audio_video?
  mute_audio(state) if layer.audio? || layer.audio_video?
  end

  def mute_video(state : Bool = true)
    state = state ? 1 : 0
    do_send(Command::ScreenMute, state, name: "mute_video")
  end

  def mute_audio(state : Bool = true)
    # Do nothing if already in desired state
    return if (self[:audio_mute]?.try &.as_bool) == state
    state = state ? 0 : 1
    do_send(Command::VolumeMute, state, name: "mute_audio")
  end

  enum Ratio
    Square  = 0x01
    Wide    = 0x02
    Zoom    = 0x04
    Scan    = 0x09
    Program = 0x06
  end
  def aspect_ratio(ratio : Ratio)
    do_send(Command::AspectRatio, ratio.value, name: "aspect_ratio", delay: 1.second)
  end

  def do_poll
    if @rs232
      power?
      if self[:hard_power]?.try &.as_bool
        screen_mute?
        input?
        volume_mute?
        volume?
      end
    elsif @connected
      screen_mute?

      if @id_num == 1
        input?
        volume_mute?
        volume?
      end
    elsif self[:power_target]?.try &.as_bool
      power(true)
    end
  end

  def input?(priority : Int32 = 0)
    do_send(Command::Input, 0xFF, 'x', priority: priority)
  end

  {% for name in ["Volume", "Contrast", "Brightness", "Sharpness"] %}
    @[Security(Level::Administrator)]
    def {{name.id.downcase}}(value : Int32)
      val = value.clamp(0, 100)
      do_send(Command::{{name.id}}, val, name: {{name.id.downcase.stringify}})
    end
  {% end %}

  # This is only necessary for Command::PmMode and Command::NoSignalOff
  # Both the responses for contrast/no_signal_off will have data[0] == 'g'
  # Same thing for auto_off/pm_mode with data[0] == 'n'
  # We will use the send and callback method to ensure these responses are processed properly
  private def process_response(data, task)
    if (resp_value = get_response_value(data)) == -1
      task.abort
    else
      self[task.name] = task.name == "pm_mode" ? resp_value : resp_value == 1
      task.success
    end
  end

  def pm_mode(mode : Int32 = 3)
    command = build_command(Command::PmMode, mode, 's')
    send(command, name: "pm_mode") { |data, task| process_response(data, task) }
  end

  def no_signal_off(state : Bool = false)
    val = state ? 1 : 0
    command = build_command(Command::NoSignalOff, val, 'f')
    send(command, name: "no_signal_off") { |data, task| process_response(data, task) }
  end

  # 0 = Off, 1 = lock all except Power buttons, 2 = lock all buttons. Default to 2 as power off from local button results in network offline
  def local_button_lock(state : Bool = true)
    val = state ? 2 : 0
    do_send(Command::LocalButtonLock, val, 't', name: "local_button_lock")
  end

  def auto_off(state : Bool = false)
    val = state ? 1 : 0
    do_send(Command::AutoOff, val, 'm', name: "disable_auto_off")
  end

  def wake_on_lan(state : Bool = true)
    val = state ? 1 : 0
    do_send(Command::WakeOnLan, val, 'f', name: "enable_wake_on_lan")
  end

  def wake(broadcast : String? = nil)
    if mac = setting?(String, :mac_address)
      # config is the database model representing this device
      wake_device(mac, broadcast)
      logger.debug {
        info = "Wake on Lan for MAC #{mac}"
        if b = broadcast
          info += " directed to VLAN #{b}"
        end
        info
      }
    else
      logger.warn { "No MAC address provided" }
    end
  end


  private def get_response_value(response : Bytes)
    logger.debug { "LG sent #{response}" }
    resp = String.new(response).split(' ').last
    # Default to -1 which means an error
    resp_value = -1
    if resp[0..1] == "OK" # Extract the response value
      # Special case for PM Mode
      if resp[2..3] == "0c"
        resp_value = resp[4..-2].to_i(16)
      else
        resp_value = resp[2..-2].to_i(16)
      end
    end
    resp_value
  end

  def received(data, task)
    return task.try &.abort if (resp_value = get_response_value(data)) == -1
    command = Command.from_value(data[0])
    logger.debug { "Received command #{command}" }

    case command
    when .power?
      self[:hard_power] = resp_value == 1
      self[:power] = false unless self[:hard_power].as_bool
    when .input?
      self[:input] = Input.from_value(resp_value)
    when .aspect_ratio?
      self[:aspect_ratio] = Ratio.from_value(resp_value)
    when .screen_mute?
      self[:power] = resp_value == 0
    when .volume_mute?
      self[:audio_mute] = resp_value == 0
    when .contrast?, .brightness?, .sharpness?, .volume?
      self[command.to_s.underscore] = resp_value
    when .wake_on_lan?, .auto_off?
      self[command.to_s.underscore] = resp_value == 1
    when .local_button_lock?
      self[:local_button_lock] = resp_value == 2
    else
      return task.try &.retry
    end

    task.try &.success
  end

  # From manual
  # [Command1]: identifies between the factory setting and the user setting modes.
  # Default c1 to 'k' which appears to be for user settings
  # and which most commands use (e.g. Mute, Screen off, Volume, Brightness)
  # Note: this is not a Command instance method as this needs access to @id
  private def build_command(command : Command, data : Int, c1 : Char = 'k')
    # Command::PmMode and Command::AutoOff both are equal to 0x6E == 'n'
    # However, PmMode has c1 == 's' while AutoOff has c1 == 'm'
    # So this is how we can differentiate whether the command we want to send is PmMode
    if command.pm_mode? && c1 == 's'
      "#{c1}#{command.value.chr} #{@id} 0c #{data.to_s(16, true).rjust(2, '0')}\r"
    else
      "#{c1}#{command.value.chr} #{@id} #{data.to_s(16, true).rjust(2, '0')}\r"
    end
  end

  private def do_send(command : Command, data : Int, c1 : Char = 'k', **options)
    send(build_command(command, data, c1), **options)
  end
end
