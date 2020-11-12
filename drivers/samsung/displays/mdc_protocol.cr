require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Samsung::Displays::MDCProtocol < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  INDICATOR = 0xAA_u8

  enum Input
    Vga         = 0x14 # pc in manual
    Dvi         = 0x18
    DviVideo    = 0x1F
    Hdmi        = 0x21
    HdmiPc      = 0x22
    Hdmi2       = 0x23
    Hdmi2Pc     = 0x24
    Hdmi3       = 0x31
    Hdmi3Pc     = 0x32
    Hdmi4       = 0x33
    Hdmi4Pc     = 0x34
    DisplayPort = 0x25
    Dtv         = 0x40
    Media       = 0x60
    Widi        = 0x61
    MagicInfo   = 0x20
    Whiteboard  = 0x64
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 1515
  descriptive_name "Samsung MD, DM & QM Series LCD"
  generic_name :Display

  # Markdown description
  description <<-DESC
  For DM displays configure the following 1:

  1. Network Standby = ON
  2. Set Auto Standby = OFF
  3. Set Eco Solution, Auto Off = OFF

  Hard Power off displays each night and hard power ON in the morning.
  DESC

  default_settings({
    display_id:    0,
    rs232_control: false,
  })

  @id : UInt8 = 0
  @rs232 : Bool = false
  @blank : Input?
  @previous_volume : Int32 = 50
  @input_stable : Bool = true
  @input_target : Input? = nil
  @power_stable : Bool = true
  @power_target : Bool = true

  def on_load
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek
      # Ensure message indicator is well-formed
      disconnect unless bytes.first == INDICATOR
      logger.debug { "Received: #{bytes}" }
      # [header, command, id, data.size, [data], checksum]
      # return 0 if the message is incomplete
      bytes.size < 4 ? 0 : bytes[3].to_i + 5
    end

    on_update
  end

  def on_update
    @id = setting(UInt8, :display_id)
    @rs232 = setting(Bool, :rs232_control)
    @blank = setting?(String, :blanking_input).try &->Input.parse(String)
  end

  def connected
    do_device_config unless self[:hard_off]?.try &.as_bool

    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    self[:power] = false unless @rs232
    schedule.clear
  end

  # As true power off disconnects the server we only want to power off the panel
  def power(state : Bool)
    @power_target = state
    @power_stable = false

    if state
      # Power on
      do_send(Command::HardOff, 1)
      do_send(Command::PanelMute, 0)
    else
      # Blank the screen before turning off panel if required
      # required by some video walls where screens are chained
      if (blanking_input = @blank) && self[:power]?
        switch_to(blanking_input)
      end
      do_send(Command::PanelMute, 1)
    end
  end

  def hard_off
    do_send(Command::PanelMute, 0) if self[:power]?.try &.as_bool
    do_send(Command::HardOff, 0)
  end

  def power?(**options) : Bool
    do_send(Command::PanelMute, Bytes.empty, **options).get
    !!self[:power]?.try(&.as_bool)
  end

  # Mutes both audio/video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    mute_video(state) if layer.video? || layer.audio_video?
    mute_audio(state) if layer.audio? || layer.audio_video?
  end

  # Adds video mute state compatible with projectors
  def mute_video(state : Bool = true)
    state = state ? 1 : 0
    do_send(Command::PanelMute, state)
  end

  # Emulate audio mute
  def mute_audio(state : Bool = true)
    # Do nothing if already in desired state
    return if self[:audio_mute]?.try(&.as_bool) == state
    self[:audio_mute] = state
    if state
      @previous_volume = self[:volume]?.try(&.as_i) || 0
      volume(0)
    else
      volume(@previous_volume)
    end
  end

  # check software version
  def software_version
    do_send(Command::SoftwareVersion)
  end

  def serial_number
    do_send(Command::SerialNumber)
  end

  def switch_to(input : Input, **options)
    @input_stable = false
    @input_target = input
    do_send(Command::Input, input.value, **options)
  end

  enum SpeakerMode
    Internal = 0
    External = 1
  end

  def speaker_select(mode : SpeakerMode, **options)
    do_send(Command::Speaker, mode.value, **options)
  end

  def do_poll
    do_send(Command::Status, Bytes.empty, priority: 0)
    power? unless self[:hard_off]?.try &.as_bool
  end

  DEVICE_SETTINGS = {
    network_standby: Bool,
    auto_off_timer:  Bool,
    auto_power:      Bool,
    volume:          Int32,
    contrast:        Int32,
    brightness:      Int32,
    sharpness:       Int32,
    colour:          Int32,
    tint:            Int32,
    red_gain:        Int32,
    green_gain:      Int32,
    blue_gain:       Int32,
  }
  {% for name, kind in DEVICE_SETTINGS %}
    @[Security(Level::Administrator)]
    def {{name.id}}(value : {{kind}}, **options)
      {% if kind.resolve == Bool %}
        state = value ? 1 : 0
        data = {{name.id.stringify}} == "auto_off_timer" ? Bytes[0x81, state] : state
      {% elsif kind.resolve == Int32 %}
        data = value.clamp(0, 100)
      {% end %}
      do_send(Command.parse({{name.id.stringify}}), data, **options)
    end
  {% end %}

  def do_device_config
    {% for name, kind in DEVICE_SETTINGS %}
      %value = setting?({{kind}}, {{name.id.stringify}})
      {{name.id}}(%value) unless %value.nil?
    {% end %}
  end

  enum ResponseStatus
    Ack = 0x41 # A
    Nak = 0x4e # N
  end

  def received(data, task)
    hex = data.hexstring
    logger.debug { "Samsung sent: #{hex}" }

    # Calculate checksum of response
    checksum = data[1..-2].reduce(&.+)

    if data[-1] != checksum
      logger.error { "Invalid checksum, checksum should be: #{checksum.to_s(16)}" }
      return task.try &.retry
    end

    status = ResponseStatus.from_value(data[4])
    command = Command.from_value(data[5])
    values = data[6..-2]
    value = values.first

    case status
    when .ack?
      case command
      when .status?
        self[:hard_off] = hard_off = values[0] == 0
        self[:power] = false if hard_off
        self[:volume] = values[1]
        self[:audio_mute] = values[2] == 1
        self[:input] = Input.from_value(values[3])
        check_power_state
      when .panel_mute?
        self[:power] = value == 0
        check_power_state
      when .volume?
        self[:volume] = value
        self[:audio_mute] = false if value > 0
      when .brightness?
        self[:brightness] = value
      when .input?
        current_input = Input.from_value(value)
        self[:input] = current_input
        # The input feedback behaviour seems to go a little odd when
        # screen split is active. Ignore any input forcing when on.
        unless self[:screen_split]?.try &.as_bool
          @input_stable = current_input == (input_target = @input_target)
          switch_to(input_target) if input_target && !@input_stable
        end
      when .speaker?
        self[:speaker] = SpeakerMode.from_value(value)
      when .hard_off?
        unless self[:hard_off]?.try &.as_bool
          self[:hard_off] = hard_off = value == 0
          self[:power] = false if hard_off
        end
      when .screen_split?
        self[:screen_split] = value >= 0
      when .software_version?
        self[:software_version] = values.join
      when .serial_number?
        self[:serial_number] = values.join
      else
        logger.debug { "Samsung responded with ACK: #{value}" }
      end

      task.try &.success
    when .nak?
      task.try &.abort("Samsung responded with NAK: #{hex}")
    else
      task.try &.retry
    end
  end

  private def check_power_state
    return if @power_stable
    if self[:power]?.try(&.as_bool) == @power_target
      @power_stable = true
    else
      power(@power_target)
    end
  end

  enum Command : UInt8
    Status          = 0x00
    HardOff         = 0x11 # Completely powers off
    PanelMute       = 0xF9 # Screen blanking / visual mute
    Volume          = 0x12
    Contrast        = 0x24
    Brightness      = 0x25
    Sharpness       = 0x26
    Colour          = 0x27
    Tint            = 0x28
    RedGain         = 0x29
    GreenGain       = 0x2A
    BlueGain        = 0x2B
    Input           = 0x14
    Mode            = 0x18
    Size            = 0x19
    Pip             = 0x3C # picture in picture
    AutoAdjust      = 0x3D
    WallMode        = 0x5C # Video wall mode
    Safety          = 0x5D
    WallOn          = 0x84 # Video wall enabled
    WallUser        = 0x89 # Video wall user control
    Speaker         = 0x68
    NetworkStandby  = 0xB5 # Keep NIC active in standby, enable power on (without WOL)
    AutoOffTimer    = 0xE6 # Eco options (auto power off)
    AutoPower       = 0x33 # Device auto power control (presumably signal based?)
    ScreenSplit     = 0xB2 # Tri / quad split (larger panels only)
    SoftwareVersion = 0x0E
    SerialNumber    = 0x0B
    Time            = 0xA7
    Timer           = 0xA4

    def build(id : UInt8, data : Bytes) : Bytes
      Bytes.new(data.size + 5).tap do |bytes|
        bytes[0] = INDICATOR                            # Header
        bytes[1] = self.value                           # Command
        bytes[2] = id                                   # Display ID
        bytes[3] = data.size.to_u8                      # Data size
        data.each_with_index(4) { |b, i| bytes[i] = b } # Data
        bytes[-1] = bytes[1..-2].reduce(&.+)            # Checksum
      end
    end
  end

  private def do_send(command : Command, data : Int | Bytes = Bytes.empty, **options)
    data = Bytes[data] if data.is_a?(Int)
    bytes = command.build(@id, data)
    logger.debug { "Sending to Samsung: #{bytes.hexstring}" }
    send(bytes, **options)
  end
end
