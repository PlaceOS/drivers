require "placeos-driver"
require "./rack_link_protocol"

class MiddleAtlantic::RackLink < PlaceOS::Driver
  descriptive_name "RackLink Power Controller."
  generic_name :PowerController

  tcp_port 60000

  default_settings({
    username: "user",
    password: "password",
    outlets: 8,
    sequence_delay: 3,
  })

  @username : String = "user"
  @password : String = "password"
  @outlet_count : Int32 = 8
  @sequence_delay : Int32 = 3
  @outlets = {} of UInt8 => Bool

  def on_load
    queue.wait = false
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.to_slice

      next -1 if bytes.size < 2

      # Expecting structure: 0xFE <length> <data...> <checksum> 0xFF
      # Length is the count of escaped data bytes (excluding header + length)
      expected = 2 + bytes[1].to_i + 1 # header + length + escaped data + tail
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
    send RackLinkProtocol.login_packet(@username, @password)
  end

  def disconnected
    schedule.clear
  end

  def received(data : Bytes, task)
    command = data[3]
    subcommand = data[4]

    case {command, subcommand}
    when {0x02, 0x10} # login response
      if data[5] == 0x01
        logger.info { "Login successful" }
        schedule.every(60.seconds) { ping }
        schedule.every(30.seconds) { query_all_outlets }
      else
        logger.error { "Login failed" }
      end
    when {0x01, 0x01} # received ping
      logger.debug { "Received ping, replying with pong" }
      spawn { send RackLinkProtocol.pong_response }
    when {0x20, 0x10}, {0x20, 0x12}
      outlet = data[5]
      state = data[6] == 0x01
      @outlets[outlet] = state
      self["outlet_#{outlet}"] = state
    when {0x10, 0x10}
      logger.warn { "NACK received with code #{data[5]}" }
    else
      logger.debug { "Unhandled command #{command.to_s(16)} subcommand #{subcommand.to_s(16)}" }
    end

    task.try &.success
  end

  def query_all_outlets
    1.upto(@outlet_count) do |id|
      send RackLinkProtocol.query_outlet(id.to_u8)
    end
  end

  def power_on(id : Int32)
    send RackLinkProtocol.set_outlet(id.to_u8, 0x01_u8)
  end

  def power_off(id : Int32)
    send RackLinkProtocol.set_outlet(id.to_u8, 0x00_u8)
  end

  def power_cycle(id : Int32, seconds : Int32 = 5)
    send RackLinkProtocol.cycle_outlet(id.to_u8, seconds)
  end

  def outlet_status(id : Int32) : Bool
    @outlets[id.to_u8]? || false
  end

  def sequence_up
    send RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x01] + sprintf("%04d", @sequence_delay).to_slice)
  end

  def sequence_down
    send RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x03] + sprintf("%04d", @sequence_delay).to_slice)
  end

  def ping
    # not expected to send ping, only respond. but can simulate
    logger.debug { "(Simulating) ping" }
  end
end
