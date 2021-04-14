require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/Sony/Sony_Q004_R1_protocol.pdf
#  also https://aca.im/driver_docs/Sony/TCP_CMDs.pdf

class Sony::Projector::PjTalk < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  descriptive_name "Sony Projector PjTalk"
  generic_name :Display
  tcp_port 53484

  default_settings({
    community: "SONY",
  })

  @community : String = ""

  def on_load
    # abstract tokenizer
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.to_slice

      # Min message length is 8 bytes
      # return the message length
      bytes.size < 10 ? -1 : 10 + bytes[9]
    end

    on_update
  end

  def on_update
    @community = setting?(String, :community) || "SONY"
  end

  def connected
    schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    if state
      # Need to send twice in case of deep sleep
      logger.debug { "requested to power on" }
      do_send(:set, :power_on, name: :power)
    else
      logger.debug { "requested to power off" }
      do_send(:set, :power_off, name: :power, delay: 3.seconds)
    end

    # Request status update
    power?(priority: 50)
  end

  def power?(priority : Int32 = 0, **options)
    do_send(:get, :power_status, **options, priority: priority).get
    !!self[:power].try(&.as_bool)
  end

  enum Input
    HDMI    = 0x0003 # same as InputB
    InputA  = 0x0002
    InputB  = 0x0003
    InputC  = 0x0004
    InputD  = 0x0005
    USB     = 0x0006 # USB type B
    Network = 0x0007 # network

    def to_bytes : Bytes
      Bytes[self.value >> 8, self.value & 0xFF]
    end

    def self.from_bytes(b : Bytes)
      Input.from_value((b[0].to_u16 << 8) + b[1])
    end
  end

  include PlaceOS::Driver::Interface::InputSelection(Input)

  def switch_to(input : Input)
    do_send(:set, :input, input.to_bytes) # , delay_on_receive: 500.milliseconds)
    logger.debug { "requested to switch to: #{input}" }

    input?
  end

  def input?
    do_send(:get, :input, priority: 0)
  end

  def lamp_time?
    do_send(:get, :lamp_timer, priority: 0)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    do_send(:set, :mute, Bytes[0, state ? 1 : 0]) # , delay_on_receive: 500)
    mute?
  end

  def mute?
    do_send(:get, :mute, priority: 0)
  end

  METHODS = [:contrast, :brightness, :color, :hue, :sharpness]

  {% for name in METHODS %}
    @[Security(Level::Administrator)]
    def {{name.id}}?
      do_send(:get, {{name}}, priority: 0)
    end
  {% end %}

  {% for name in METHODS %}
    @[Security(Level::Administrator)]
    def {{name.id}}(value : UInt8)
      do_send(:set, {{name}}, Bytes[0, value.clamp(0, 100)], priority: 0)
    end
  {% end %}

  enum Command
    PowerOn     = 0x172E
    PowerOff    = 0x172F
    Input       = 0x0001
    Mute        = 0x0030
    ErrorStatus = 0x0101
    PowerStatus = 0x0102
    Contrast    = 0x0010
    Brightness  = 0x0011
    Color       = 0x0012
    Hue         = 0x0013
    Sharpness   = 0x0014
    LampTimer   = 0x0113

    def to_bytes : Bytes
      Bytes[self.value >> 8, self.value & 0xFF]
    end

    def self.from_bytes(b : Bytes)
      Command.from_value((b[0].to_u16 << 8) + b[1])
    end
  end

  enum CommandType : UInt8
    Set = 0
    Get
  end

  PJTALK_HEADER = Bytes[0x02, 0x0a]

  protected def do_send(cmd_type : CommandType, command : Command, param : Bytes? = nil, name : String | Symbol? = nil, **options)
    io = IO::Memory.new(14)
    io.write PJTALK_HEADER
    io << @community
    io.write_byte(cmd_type.value)
    io.write(command.to_bytes)

    if param
      io.write_byte param.size.to_u8
      io.write param
    else
      io.write_byte 0_u8
    end

    send(io.to_slice, **options, name: name || (param ? "#{command}_req" : command))
  end

  def do_poll
    if power?
      input?
      mute?
      do_send(:get, :error_status, priority: 0)
      lamp_time?
    end
  end

  enum ResponseStatus : UInt8
    NoGood = 0
    Okay
  end

  def received(data, task)
    logger.debug { "sony proj sent: 0x#{data.hexstring}" }

    response_status = ResponseStatus.from_value data[6]
    pjt_command = Command.from_bytes data[7..8]
    pjt_length = data[9]
    pjt_data = pjt_length > 0 ? data[10..-1] : Bytes.new(0)

    # check for error response
    if response_status.no_good?
      category = ERROR_CATEGORY[pjt_data[0]]? || :unknown
      message = ERRORS[category][pjt_data[1]]? || "unknown: category #{pjt_data[1].to_s(16)}, reason #{pjt_data[1].to_s(16)}"

      self[:last_error] = "#{category}: #{message}"
      logger.debug { "Command #{pjt_command} failed with #{category}: #{message}" }
      return task.try &.abort
    end

    # process a successful response
    case pjt_command
    when .power_on?
      self[:power] = true
    when .power_off?
      self[:power] = false
    when .lamp_timer?
      # Two bytes converted to a 16bit integer
      # we use negative indexes as can be a 32bit response (only 16bits needed)
      self[:lamp_usage] = (pjt_data[-2].to_u16 << 8) + pjt_data[-1]
    when .power_status?
      case pjt_data[-1]
      when 0, 8
        self[:warming] = self[:cooling] = self[:power] = false
      when 1, 2
        self[:cooling] = false
        self[:warming] = self[:power] = true
      when 3
        self[:power] = true
        self[:warming] = self[:cooling] = false
      when 4, 5, 6, 7
        self[:cooling] = true
        self[:warming] = self[:power] = false
      end
      schedule.in(5.seconds) { power? } if self[:warming] || self[:cooling]
    when .mute?
      self[:mute] = pjt_data[-1] == 1
    when .input?
      self[:input] = Input.from_bytes(pjt_data)
    when .contrast?, .brightness?, color?, .hue?, .sharpness?
      self[pjt_command.to_s.downcase] = pjt_data[-1]
    end

    task.try &.success
  end

  ERROR_CATEGORY = {
    0x01_u8 => :item_error,
    0x02_u8 => :community_error,
    0x10_u8 => :request_error,
    0x20_u8 => :network_error,
    0xF0_u8 => :comms_error,
    0xF1_u8 => :ram_error,
  }

  ERRORS = {
    item_error: {
      0x01_u8 => "Invalid Item",
      0x02_u8 => "Invalid Item Request",
      0x03_u8 => "Invalid Length",
      0x04_u8 => "Invalid Data",
      0x11_u8 => "Short Data",
      0x80_u8 => "Not Applicable Item",
    },
    community_error: {
      0x01_u8 => "Different Community",
    },
    request_error: {
      0x01_u8 => "Invalid Version",
      0x02_u8 => "Invalid Category",
      0x03_u8 => "Invalid Request",
      0x11_u8 => "Short Header",
      0x12_u8 => "Short Community",
      0x13_u8 => "Short Command",
    },
    network_error: {
      0x01_u8 => "Timeout",
    },
    comms_error: {
      0x01_u8 => "Timeout",
      0x10_u8 => "Check Sum Error",
      0x20_u8 => "Framing Error",
      0x30_u8 => "Parity Error",
      0x40_u8 => "Over Run Error",
      0x50_u8 => "Other Comm Error",
      0xF0_u8 => "Unknown Response",
    },
    ram_error: {
      0x10_u8 => "Read Error",
      0x20_u8 => "Write Error",
    },
    unknown: {} of UInt8 => String,
  }
end
