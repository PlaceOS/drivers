require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "bindata"

# Protocol: https://aca.im/driver_docs/X3M/RS-232%20Instructions.pdf

class Company3M::Displays::WallDisplay < PlaceOS::Driver
  include Interface::Powerable
  include Interface::AudioMuteable

  enum Input
    VGA         = 0
    DVI         = 1
    HDMI        = 2
    DisplayPort = 3
  end

  include Interface::InputSelection(Input)

  # Discovery Information
  descriptive_name "3M Wall Display"
  generic_name :Display
  description <<-DESC
    Display control is via RS-232 only. Ensure IP -> RS-232 converter has
    been configured to provide comms at 9600,N,8,1.
  DESC

  # Global Cache Port
  tcp_port 4999

  default_settings({
    # 0 == all monitors
    monitor_id: "all",
  })

  @monitor_id : MonitorID = MonitorID::All
  @power_target : Bool? = nil

  def on_load
    transport.tokenizer = Tokenizer.new("\r")
    on_update
  end

  def on_update
    @monitor_id = setting?(MonitorID, :monitor_id) || MonitorID::All
  end

  def connected
    schedule.every(15.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def do_poll
    logger.debug { "Polling device for connectivity heartbeat" }

    # The device does not provide any query only methods for interaction.
    # Re-apply the current known power state to provide a comms heartbeat
    # if we can do it safely.
    target = @power_target
    power(target, priority: 0) unless target.nil?
  end

  # ===================
  # Powerable Interface
  # ===================

  def power(state : Bool, **options)
    if state != @power_target
      # Define setting for polling
      self[:power_target] = @power_target = state
    end
    set :power, state, **options
  end

  # ====================
  # Audio Mute Interface
  # ====================

  def mute_audio(state : Bool = true, index : Int32 | String = 0)
    set :audio_mute, state
  end

  # =========================
  # Input selection Interface
  # =========================

  def switch_to(input : Input)
    set :input, input
  end

  # ==============
  # End Interfaces
  # ==============

  protected def in_range(level : Int32 | Float64) : Int32
    level = level.to_f.clamp(0.0, 100.0)
    level.round.to_i
  end

  def volume(level : Int32 | Float64)
    percentage = in_range(level) / 100.0
    adjusted = (percentage * 30.0).round_away.to_i
    set :volume, adjusted
  end

  def brightness(value : Int32 | Float64)
    value = in_range value
    set :brightness, value
  end

  def contrast(value : Int32 | Float64)
    value = in_range value
    set :contrast, value
  end

  def sharpness(value : Int32 | Float64)
    value = in_range value
    set :sharpness, value
  end

  enum ColourTemp
    K9300 = 0
    K6500 = 1
    User  = 2
  end

  def colour_temp(value : ColourTemp)
    set :colour_temp, value
  end

  protected def set(command : Command, param, **opts)
    logger.debug { "Setting #{command} -> #{param}" }

    request = new_request command, param
    packet = build_packet request
    send packet, **opts, name: command.to_s
  end

  def received(bytes, task)
    response = begin
      parse_response bytes
    rescue parse_error
      logger.warn(exception: parse_error) { "failed to parse 3M packet" }
      return task.try &.abort
    end

    unless response.success?
      logger.warn { "Device error: #{response.inspect}" }
      return task.try &.abort
    end

    logger.debug { "Device response received: #{response.inspect}" }

    self[response.command.to_s.underscore] = response.value
    task.try &.success
  end

  enum MonitorID : UInt8
    All = 0x2a
    A   = 0x41
    B   = 0x42
    C   = 0x43
    D   = 0x44
    E   = 0x45
    F   = 0x46
    G   = 0x47
    H   = 0x48
    I   = 0x49
  end

  enum MessageSender
    PC = 0x30
  end

  enum MessageType : UInt8
    Command = 0x45
    Reply   = 0x46
  end

  enum Command : UInt16
    Brightness = 0x0110
    Contrast   = 0x0112
    Sharpness  = 0x018c
    ColourTemp = 0x0254
    Volume     = 0x0062
    AudioMute  = 0x008d
    Input      = 0x02cb
    Power      = 0x0003
  end

  enum ResultCode : UInt16
    Success     = 0x3030
    Unsupported = 0x3031
  end

  class RequestPacket < BinData
    endian big

    uint8 :header_start, value: ->{ 0x01_u8 }
    uint8 :reserved, value: ->{ 0x30_u8 }
    enum_field UInt8, monitor_id : MonitorID = MonitorID::All
    enum_field UInt8, sender : MessageSender = MessageSender::PC
    enum_field UInt8, message_type : MessageType = MessageType::Command
    string :message_length, value: ->{ 10.to_s(16).upcase.rjust(2, '0') }, length: ->{ 2 }

    uint8 :message_start, value: ->{ 0x02_u8 }
    string :op_code_page, length: ->{ 2 }
    string :op_code, length: ->{ 2 }
    string :set_value, length: ->{ 4 }
    uint8 :message_end, value: ->{ 0x03_u8 }

    def command=(command : Command)
      code = command.value.to_s(16).upcase.rjust(4, '0')
      self.op_code_page = code[0..1]
      self.op_code = code[2..3]
      command
    end

    def value=(val : Int32)
      self.set_value = val.to_s(16).upcase.rjust(4, '0')
    end
  end

  class ResponsePacket < BinData
    endian big

    uint8 :header_start
    uint8 :reserved
    enum_field UInt8, receiver : MessageSender = MessageSender::PC
    enum_field UInt8, monitor_id : MonitorID = MonitorID::All
    enum_field UInt8, message_type : MessageType = MessageType::Reply
    string :message_length, length: ->{ 2 }

    uint8 :message_start, value: ->{ 0x02_u8 }
    enum_field UInt16, result_code : ResultCode = ResultCode::Success
    string :op_code_page, length: ->{ 2 }
    string :op_code, length: ->{ 2 }
    string :reply_type, length: ->{ 2 }
    string :max_value, length: ->{ 4 }
    string :current_value, length: ->{ 4 }
    uint8 :message_end
    uint8 :bcc
    uint8 :delimiter

    getter command : Command do
      Command.from_value "#{op_code_page}#{op_code}".to_i(16)
    end

    def success?
      self.result_code.success?
    end

    def value
      raw_val = self.current_value.to_i(16)
      case self.command
      in .brightness?, .contrast?, .sharpness?
        raw_val
      in .volume?
        # adjust back into 0-100 range
        (raw_val / 30.0) * 100.0
      in .audio_mute?, .power?
        raw_val == 1
      in .colour_temp?
        ColourTemp.from_value raw_val
      in .input?
        Input.from_value raw_val
      end
    end
  end

  # Map a symbolic command and parameter value to an [op_code, value]
  protected def new_request(command : Command, param : Bool | Enum | Int32)
    value = case param
            in Bool
              param ? 1 : 0
            in Enum
              param.to_i
            in Int32
              param
            end

    request = RequestPacket.new
    request.command = command
    request.value = value
    request
  end

  # Build a "set_parameter_command" packet ready for transmission
  protected def build_packet(request : RequestPacket) : Bytes
    request.monitor_id = @monitor_id
    io = IO::Memory.new
    io.write_bytes(request)

    bytes = io.to_slice
    io.write_byte(bytes[1..-1].reduce { |acc, i| acc ^ i })
    io << "\r"
    io.to_slice
  end

  protected def parse_response(packet : Bytes) : ResponsePacket
    io = IO::Memory.new(packet)
    response = io.read_bytes(ResponsePacket)

    bcc = packet[1..-3].reduce { |acc, i| acc ^ i }
    raise "invalid checksum" if bcc != response.bcc

    response
  end
end
