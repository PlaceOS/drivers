require "placeos-driver"
require "./rack_link_protocol"

# docs: https://res.cloudinary.com/avd/image/upload/v133928820/Resources/Middle%20Atlantic/Power/Firmware/I-00472-Series-Protocol.pdf

class MiddleAtlantic::RackLink < PlaceOS::Driver
  descriptive_name "RackLink Power Controller."
  generic_name :PowerController

  tcp_port 60000

  default_settings({
    username:       "user",
    password:       "password",
    outlets:        8,
    sequence_delay: 3,
  })

  @username : String = "user"
  @password : String = "password"
  @outlet_count : Int32 = 8
  @sequence_delay : Int32 = 3
  @outlets = {} of UInt8 => Bool

  def on_load
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.to_slice

      next -1 if bytes.size < 2

      # Expecting structure: 0xFE <length> <data...> <checksum> 0xFF
      # Length is the count of escaped data bytes (excluding header + length)
      expected = 4 + bytes[1].to_i
      bytes.size >= expected ? expected : -1
    end

    on_update
  end

  def on_update
    @username = setting?(String, :username) || "user"
    @password = setting?(String, :password) || "password"
    @outlet_count = setting?(Int32, :outlets) || 8
    @sequence_delay = setting?(Int32, :sequence_delay) || 3
  end

  def connected
    authenticate
  end

  def disconnected
    schedule.clear
  end

  protected def authenticate
    do_send RackLinkProtocol.login_packet(@username, @password), name: "authenticate", priority: 99
  end

  enum NACK
    BadCRC             = 1
    BadLength
    BadEscape
    InvalidCommand
    InvalidSubCommand
    IncorrectByteCount
    InvalidDataBytes
    InvalidCredentials
    UnknownError       = 0x10
    AccessDenied
  end

  def received(data : Bytes, task)
    logger.debug { "received: 0x#{data.hexstring}" }

    command = data[3]
    subcommand = data[4]

    case {command, subcommand}
    when {0x02, 0x10} # login response
      if data[5] == 0x01
        logger.info { "Login successful" }
        self[:connected] = true
        schedule.every(50.seconds) { query_all_outlets }
      else
        logger.error { "Login failed" }
        self[:connected] = false
        schedule.in(30.seconds) { authenticate }
      end
    when {0x01, 0x01} # received ping
      logger.debug { "Received ping, replying with pong" }
      do_send RackLinkProtocol.pong_response, wait: false
    when {0x20, 0x10}, {0x20, 0x12}
      outlet = data[5]
      state = data[6] == 0x01
      @outlets[outlet] = state
      self["outlet_#{outlet}"] = state
    when {0x10, 0x10}
      error_code = data[5]
      error = NACK.from_value(error_code) rescue NACK::UnknownError
      last_error = "Error #{error_code}: #{error}"
      logger.error { last_error }

      if error.invalid_credentials?
        logger.error { "Login failed" }
        self[:connected] = false
        schedule.in(30.seconds) { authenticate }
      end

      return task.try &.abort
    else
      logger.debug { "Unhandled command #{command.to_s(16)} subcommand #{subcommand.to_s(16)}" }
    end

    task.try &.success
  end

  def query_all_outlets
    1.upto(@outlet_count) do |id|
      do_send RackLinkProtocol.query_outlet(id.to_u8)
    end
  end

  def power_on(id : Int32)
    do_send RackLinkProtocol.set_outlet(id.to_u8, 0x01_u8)
  end

  def power_off(id : Int32)
    do_send RackLinkProtocol.set_outlet(id.to_u8, 0x00_u8)
  end

  def power_cycle(id : Int32, seconds : Int32 = 5)
    do_send RackLinkProtocol.cycle_outlet(id.to_u8, seconds)
  end

  def outlet_status(id : Int32) : Bool
    @outlets[id.to_u8]? || false
  end

  def sequence_up
    do_send RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x01] + sprintf("%04d", @sequence_delay).to_slice)
  end

  def sequence_down
    do_send RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x03] + sprintf("%04d", @sequence_delay).to_slice)
  end

  protected def do_send(bytes : Bytes, **opts)
    logger.debug { "sending: 0x#{bytes.hexstring}" }
    send bytes, **opts
  end
end
