require "placeos-driver"
require "placeos-driver/interface/lighting"

# Documentation: https://aca.im/driver_docs/Clipsal/CBUS-Lighting-Application.pdf
#  and https://aca.im/driver_docs/Clipsal/CBUS-Trigger-Control-Application.pdf

class Clipsal::CBus < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  # Discovery Information
  descriptive_name "Clipsal CBus Lighting"
  generic_name :Lighting
  tcp_port 10001

  default_settings({
    trigger_groups: [0xCA],
  })

  @trigger_groups : Array(UInt8) = [0xCA_u8]

  def on_load
    queue.wait = false
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new("\r")

    on_update
  end

  def on_update
    @trigger_groups = setting?(Array(UInt8), :trigger_groups) || [0xCA_u8]
  end

  def disconnected
    schedule.clear
  end

  def connected
    # Ensure we are in smart mode
    send("|||\r", priority: 99)

    # maintain the connection
    schedule.every(1.minute) do
      logger.debug { "maintaining connection" }
      send("|||\r", priority: 0)
    end
  end

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    application, group = get_application_group(area, 0xCA)
    action = scene & 0xFF
    command = Bytes[0x05, application, 0x00, 0x02, group, action.to_u8]

    self[area] = action

    do_send(command)
  end

  def lighting_scene?(area : Area? = nil)
    _application, group = get_application_group(area, 0xCA)
    self[Area.new(group.to_u32)]?
  end

  RAMP_RATES = {
    (...2_000_u32)              => 0b0000_u8, # instant
    (2_000_u32...6_000_u32)     => 0b0001_u8, # 4s
    (6_000_u32...10_000_u32)    => 0b0010_u8, # 8s
    (10_000_u32...15_000_u32)   => 0b0011_u8, # 12s
    (15_000_u32...25_000_u32)   => 0b0100_u8, # 20s
    (25_000_u32...35_000_u32)   => 0b0101_u8, # 30s
    (35_000_u32...50_000_u32)   => 0b0110_u8, # 40s
    (50_000_u32...75_000_u32)   => 0b0111_u8, # 1m
    (75_000_u32...105_000_u32)  => 0b1000_u8, # 1m 30s
    (105_000_u32...150_000_u32) => 0b1001_u8, # 2m
    (150_000_u32...240_000_u32) => 0b1010_u8, # 3m
    (240_000_u32...360_000_u32) => 0b1011_u8, # 5m
    (360_000_u32...510_000_u32) => 0b1100_u8, # 7m
    (510_000_u32...720_000_u32) => 0b1101_u8, # 10m
    (720_000_u32...960_000_u32) => 0b1110_u8, # 15m
    (960_000_u32...)            => 0b1111_u8, # 17m
  }

  def lookup_ramp_rate(fade_time : UInt32) : UInt8
    range = RAMP_RATES.keys.find(&.includes?(fade_time))
    rate = RAMP_RATES[range]

    # The command is structured as: 0b0xxxx010 where xxxx == rate
    ((rate & 0x0F_u8) << 3) | 0b010_u8
  end

  LEVEL_PERCENTAGE = 0xFF / 100

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    application, group = get_application_group(area, 0x38)

    level = level.clamp(0.0, 100.0)
    level_byte = (level * LEVEL_PERCENTAGE).to_u8
    group = (group & 0xFF).to_u8
    rate = lookup_ramp_rate(fade_time)

    # stop_fading(group)
    stop_f = cmd_string(Bytes[0x05, 0x38, 0x00, 0x09, group])
    command = stop_f + cmd_string(Bytes[0x05, application, 0x00, rate, group, level_byte])

    self["#{area}_level"] = level

    send(command, name: "level_#{application}_#{group}")
  end

  def stop_fading(group : UInt8)
    do_send(Bytes[0x05, 0x38, 0x00, 0x09, group])
  end

  # return the current level
  def lighting_level?(area : Area? = nil)
    _application, group = get_application_group(area, 0x38)
    self[Area.new(group.to_u32, append: "level")]?
  end

  def received(data, task)
    # extract the hex string encoded bytes
    payload = String.new(data)
    logger.debug { "CBus sent: #{payload}" }
    data = payload[1..-2].hexbytes

    if !check_checksum(data)
      return task.try(&.abort("CBus checksum failed"))
    end

    # We are only looking at Point -> MultiPoint commands
    # 0x03 == Point -> Point -> MultiPoint
    # 0x06 == Point -> Point
    if data[0] != 0x05
      logger.debug { "was not a Point -> MultiPoint response: type 0x#{data[0].to_s(16)}" }
      return
    end

    application = data[1]       # The application being referenced
    commands = data[3..-2].to_a # Remove the header + checksum

    while commands.size > 0
      current = commands.shift

      case application
      when .in?(@trigger_groups) # Trigger group
        area = if application == 0xCA_u8
                 Area.new(commands.shift.to_u32)
               else
                 Area.new(commands.shift.to_u32, channel: application.to_u32)
               end

        case current
        when 0x02                     # Trigger Event (ex: 0504CA00 020101 29)
          self[area] = commands.shift # Action selector
        when 0x01                     # Trigger Min
          self[area] = 0
        when 0x79 # Trigger Max
          self[area] = 0xFF
        when 0x09 # Indicator Kill (ex: 0504CA00 0901 23)
          logger.debug { "trigger kill request: grp 0x#{commands[0].to_s(16)}" }
          # Group (turns off indicators of all scenes triggered by this group)
        else
          logger.debug { "unknown trigger group request 0x#{current.to_s(16)}" }
          break # We don't know what data is here
        end
      when 0x30..0x5F # Lighting group
        case current
        when 0x01 # Group off (ex: 05043800 0101 0102 0103 0104 7905 33)
          self[Area.new(commands.shift.to_u32, append: "level")] = 0.0
        when 0x79 # Group on (ex: 05013800 7905 44)
          self[Area.new(commands.shift.to_u32, append: "level")] = 100.0
        when 0x02 # Blinds up or stop
          # Example: 05083000022FFF93
          group = commands.shift
          value = commands.shift
          area = Area.new(group.to_u32, append: "blind")

          if value == 0xFF
            self[area] = :up
          elsif value == 5
            self[area] = :stopped
          end
        when 0x1A # Blinds down
          # Example: 050830001A2F007A
          group = commands.shift
          value = commands.shift
          self[Area.new(group.to_u32, append: "blind")] = :down if value == 0x00
        when 0x09 # Terminate Ramp
          logger.debug { "terminate ramp request: grp 0x#{commands[0].to_s(16)}" }
          commands.shift # Group address
        else
          # Ramp to level (ex: 05013800 0205FF BC)
          #                    Header   cmd    cksum
          if ((current & 0b10000101) == 0) && commands.size > 1
            logger.debug { "ramp request: grp 0x#{commands[0].to_s(16)} - level 0x#{commands[1].to_s(16)}" }
            commands.shift(2) # Group address, level
          else
            logger.debug { "unknown lighting request 0x#{current.to_s(16)}" }
            break # We don't know what data is here
          end
        end
      else
        logger.debug { "unknown application request app 0x#{application.to_s(16)}" }
        break # We haven't programmed this application
      end
    end

    task.try &.success
  end

  protected def get_application_group(area : Area?, app_default = 0x38)
    group = area.try &.id
    raise "area (cbus group) id required" unless group
    application = (area.try(&.channel) || app_default).to_u8

    {application, group.to_u8 & 0xFF_u8}
  end

  protected def checksum(data : Bytes) : Bytes
    check = 0
    data.each do |byte|
      check += byte
    end
    check = check % 0x100
    check = ((check ^ 0xFF) + 1) & 0xFF
    Bytes[check.to_u8]
  end

  protected def check_checksum(data : Bytes) : Bool
    check = 0
    data.each do |byte|
      check += byte
    end
    (check % 0x100) == 0x00
  end

  protected def cmd_string(command : Bytes) : String
    String.build do |str|
      str << "\\"
      str << command.hexstring.upcase
      str << checksum(command).hexstring.upcase
      str << "\r"
    end
  end

  protected def do_send(command : Bytes, **options)
    cmd = cmd_string(command)
    logger.debug { "Requesting CBus: #{cmd}" }
    send(cmd, **options)
  end
end
