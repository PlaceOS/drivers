require "placeos-driver"
require "placeos-driver/interface/lighting"

# Documentation: https://aca.im/driver_docs/Philips/Dynet%20Integrators%20hand%20book%20for%20the%20DNG232%20V2.pdf
#  also https://aca.im/driver_docs/Philips/DyNet%201%20Opcode%20Master%20List%20-%202012-08-29.xls

class Philips::Dynalite < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  # Discovery Information
  descriptive_name "Philips Dynalite Lighting"
  generic_name :Lighting
  tcp_port 50000

  def on_load
    queue.wait = false
    queue.delay = 35.milliseconds
    # 8 bytes starting with 1C
    transport.tokenizer = Tokenizer.new(8, Bytes[0x1C])
  end

  def disconnected
    schedule.clear
  end

  def connected
    # maintain the connection
    schedule.every(1.minute) do
      logger.debug { "maintaining connection" }
      get_current_preset(1)
    end
  end

  # fade_time in millisecond
  def trigger(area : Int32, scene : Int32, fade : Int32 = 1000)
    # convert to centiseconds
    fade_centi = fade // 10

    # No response so we should update status here
    self[Area.new(area.to_u32)] = scene

    # Crazy scene encoding
    # Supports presets: 1 - 24 (0 indexed)
    # Presets are in 1 of 3 banks (0 indexed)
    # Presets in a bank are encoded: 0 = P1, 1 = P2, 2 = P3, 3 = P4, A = P5, B = P6, C = P7, D = P8
    scene = scene - 1          # zero index
    bank = scene // 8          # calculate bank this preset resides in
    scene = scene - (bank * 8) # select the scene in the current bank
    scene += 6 if scene >= 4   # encode the upper bank presets (P5 -> P8)

    command = Bytes[0x1c, area & 0xFF, fade_centi & 0xFF, scene & 0xFF, (fade_centi >> 8) & 0xFF, bank, 0xFF]
    schedule.in((fade + 200).milliseconds) { get_light_level(area) }

    do_send(command, name: "preset_#{area}_#{scene}")
  end

  def get_current_preset(area : Int32)
    command = Bytes[0x1c, area & 0xFF, 0, 0x63, 0, 0, 0xFF]
    do_send(command, wait: true)
  end

  @[Security(Level::Administrator)]
  def save_preset(area : Int32, scene : Int32)
    num = (scene - 1) & 0xFF
    command = Bytes[0x1c, area & 0xFF, num, 0x09, 0, 0, 0xFF]
    do_send(command)
  end

  def lighting(area : Int32, state : Bool, fade : Int32 = 1000)
    level = state ? 100.0 : 0.0
    light_level(area, level, fade)
  end

  LEVEL_PERCENTAGE = 0xFE / 100

  def light_level(area : Int32, level : Float64, fade : Int32 = 1000, channel : Int32 = 0xFF)
    cmd = 0x71

    # Command changes based on the length of the fade time
    fade = if fade <= 25500
             fade // 100
           elsif fade < 255000
             cmd = 0x72
             fade // 1000
           else
             cmd = 0x73
             (fade // 60000).clamp(1, 22)
           end

    # Ensure status values are valid
    area_key = Area.new(area.to_u32, channel: channel == 0xFF ? nil : channel.to_u32).append("level").to_s
    self[area_key] = level

    # Levels are percentage based (on the PlaceOS side)
    # 0x01 == 100%
    # 0xFF == 0%
    level = (level.clamp(0.0, 100.0) * LEVEL_PERCENTAGE).to_u8
    level = 0xFF_u8 - level # Invert

    command = Bytes[0x1c, area & 0xFF, channel & 0xFF, cmd, level, fade & 0xFF, 0xFF]
    do_send(command, name: "level_#{area}_#{channel}")
  end

  def stop_fading(area : Int32, channel : Int32 = 0xFF)
    command = Bytes[0x1c, area & 0xFF, channel & 0xFF, 0x76, 0, 0, 0xFF]
    do_send(command, name: "level_#{area}_#{channel}")
  end

  def stop_all_fading(area : Int32)
    command = Bytes[0x1c, area & 0xFF, 0, 0x7A, 0, 0, 0xFF]
    do_send(command)
  end

  def get_light_level(area : Int32, channel : Int32 = 0xFF)
    do_send(Bytes[0x1c, area & 0xFF, channel & 0xFF, 0x61, 0, 0, 0xFF], wait: true)
  end

  def increment_area_level(area : Int32)
    do_send(Bytes[0x1c, area & 0xFF, 0x64, 6, 0, 0, 0xFF])
  end

  def decrement_area_level(area : Int32)
    do_send(Bytes[0x1c, area & 0xFF, 0x64, 5, 0, 0, 0xFF])
  end

  def unlink_area(area : Int32)
    #             0x1c, area, unlink_bitmap, 0x21, unlink_bitmap, unlink_bitmap, join (0xFF)
    do_send(Bytes[0x1c, area & 0xFF, 0xFF, 0x21, 0xFF, 0xFF, 0xFF])
  end

  def link_area(area : UInt8, join : UInt8)
    do_send(Bytes[0x1c, area, 0x00, join, 0x00, 0x00, 0xFF])
  end

  def received(data, task)
    logger.debug { "received 0x#{data.hexstring}" }

    case data[3]
    # current preset selected response
    when 0, 1, 2, 3, 10, 11, 12, 13
      # 0-3, A-D == preset 1..8
      number = data[3]
      number -= 0x0A + 4 if number > 3

      # Data 4 represets the preset offset or bank
      number += data[5] * 8 + 1
      self[Area.new(data[1].to_u32)] = number
      task.try &.success(number)

      # alternative preset response
    when 0x62
      number = data[2] + 1
      self[Area.new(data[1].to_u32)] = number
      task.try &.success(number)
      # level response (area or channel)
    when 0x60
      level = data[4]

      # 0x01 == 100%
      # 0xFF == 0%
      level = 0xFF - level
      level = level / LEVEL_PERCENTAGE
      channel = data[2].to_u32
      area_key = Area.new(data[1].to_u32, channel: channel == 0xFF_u32 ? nil : channel).append("level").to_s
      self[area_key] = level

      task.try &.success(level)
    else
      task.try &.success
    end
  end

  protected def do_send(command : Bytes, **options)
    # 2's compliment checksum (i.e. negative of the sum and the least significant byte of that result)
    check = (-command.reduce(0) { |acc, i| acc + i }) & 0xFF
    data = IO::Memory.new(command.size + 1)
    data.write command
    data.write_byte check.to_u8

    command = data.to_slice
    logger.debug { "sending: 0x#{command.hexstring}" }

    send(command, **options)
  end

  # ==================
  # Lighting Interface
  # ==================
  protected def check_arguments(area : Area?)
    area_id = area.try(&.id)
    # area_join = area.try(&.join) || 0xFF_u32
    raise ArgumentError.new("area.id required") unless area_id
    area_id.to_i
  end

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area_id = check_arguments area
    trigger(area_id, scene.to_i, fade_time.to_i)
  end

  def lighting_scene?(area : Area? = nil)
    area_id = check_arguments area
    get_current_preset(area_id.to_i)
  end

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area_id = check_arguments area
    area_channel = area.try(&.channel) || 0xFF_u32
    light_level(area_id, level, fade_time.to_i, area_channel.to_i)
  end

  def lighting_level?(area : Area? = nil)
    area_id = check_arguments area
    area_channel = area.try(&.channel) || 0xFF_u32
    get_light_level(area_id, area_channel.to_i)
  end
end
