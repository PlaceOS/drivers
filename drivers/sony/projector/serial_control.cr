require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

# Documentation: https://aca.im/driver_docs/Sony/Sony_Q004_R1_protocol.pdf
# also https://aca.im/driver_docs/Sony/TCP_CMDs.pdf

class Sony::Projector::SerialControl < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  descriptive_name "Sony Projector (RS232 Control)"
  generic_name :Display

  def on_load
  end

  def connected
    # schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    if state
      # Need to send twice in case of deep sleep
      logger.debug { "requested to power on" }
      do_send(Type::Set, Command::PowerOn, name: :power, wait: false)
      do_send(Type::Set, Command::PowerOn, name: :power, delay: 3.seconds, wait: false)
    else
      logger.debug { "requested to power off" }
      do_send(Type::Set, Command::PowerOff, name: :power, delay: 3.seconds, wait: false)
    end
    # Request status update
    power?(priority: 50)
  end

  def power?(priority : Int32 = 0, **options)
    do_send(Type::Get, Command::PowerStatus, **options, priority: priority).get
    !!self[:power].try(&.as_bool)
  end

  enum Input
    HDMI = 0x0003 # same as InputB
    InputA = 0x0002
    InputB = 0x0003
    InputC = 0x0004
    InputD = 0x0005
    USB =  0x0006 # USB type B
    Network = 0x0007 # network

    def to_bytes : Bytes
      Bytes[self.value >> 8, self.value & 0xFF]
    end

    def self.from_bytes(b : Bytes)
      Input.from_value((b[0].to_u16 << 8) + b[1])
    end
  end

  def switch_to(input : Input)
    do_send(Type::Set, Command::Input, input.to_bytes)#, delay_on_receive: 500.milliseconds)
    logger.debug { "requested to switch to: #{input}" }

    input?
  end

  def input?
    do_send(Type::Get, Command::Input, priority: 0)
  end

  def lamp_time?
    do_send(Type::Get, Command::LampTimer, priority: 0)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    do_send(Type::Set, Command::Mute, Bytes[0, state ? 0 : 1])#, delay_on_receive: 500)
  end

  METHODS = ["Contrast", "Brightness", "Color", "Hue", "Sharpness"]

  {% for name in METHODS %}
    @[Security(Level::Administrator)]
    def {{name.id.downcase}}?
      do_send(Type::Get, Command::{{name.id}}, priority: 0)
    end
  {% end %}

  {% for name in METHODS %}
    @[Security(Level::Administrator)]
    def {{name.id.downcase}}(value : UInt8)
      do_send(Type::Set, Command::{{name.id}}, Bytes[0, value.clamp(0, 100)], priority: 0)
    end
  {% end %}

  ERRORS = {
    0x00 => "No Error",
    0x01 => "Lamp Error",
    0x02 => "Fan Error",
    0x04 => "Cover Error",
    0x08 => "Temperature Error",
    0x10 => "D5V Error",
    0x20 => "Power Error",
    0x40 => "Warning Error",
    0x80 => "NVM Data ERROR"
  }

  private def do_poll
    if power?(priority: 0)
      input?
      mute?
      do_send(Type::Get, Command::ErrorStatus, priority: 0)
      lamp_time?
    end
  end

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

  enum Type : UInt8
    Set
    Get
  end

  INDICATOR = 0xA9_u8
  DELIMITER = 0x9A_u8

  private def do_send(type : Type, command : Command, param : Bytes = Bytes.new(2), **options)
    # indicator: 1, command: 2, type: 1, param: 2, checksum: 1, delimiter: 1
    data = Bytes.new(8).tap do |bytes|
      bytes[0] = INDICATOR
      command.to_bytes.each_with_index(1) { |b, i| bytes[i] = b } # bytes[1..2]
      bytes[3] = type.value
      param.each_with_index(4) { |b, i| bytes[i] = b } # bytes[4..5]
      bytes[7] = DELIMITER
    end
    data[6] = data[1..5].reduce { |a, b| a |= b } # checksum

    send(data, **options)
  end

  def received(data, task)
    logger.debug { "sony proj sent: 0x#{data.hexstring}" }

    cmd = data[0..1]
    type = data[2]
    resp = data[3..4]

    # Check if an ACK/NAK
    if type == 0x03
      if cmd == Bytes[0, 0]
        return task.try &.success
      else # Command failed TODO
        # logger.debug { "Command failed with 0x#{byte_to_hex(cmd[0])} - 0x#{byte_to_hex(cmd[1])}" }
        return task.try &.abort
      end
    else
      case command = Command.from_bytes(data[0..1])
      when .power_on?
        self[:power] = true
      when .power_off?
        self[:power] = false
      when .lamp_timer? # TODO
        # Two bytes converted to a 16bit integer
        # self[:lamp_usage] = array_to_str(data[-2..-1]).unpack('n')[0]
      when .power_status?
        case resp[-1]
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
        self[:mute] = resp[-1] == 1
      when .input?
        self[:input] = Input.from_bytes(resp)
      when .contrast?, .brightness?, color?, .hue?, .sharpness?
        self[command.to_s.downcase] = resp[-1]
      end
    end

    task.try &.success
  end
end
