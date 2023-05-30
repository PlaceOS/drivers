require "placeos-driver"
require "placeos-driver/interface/lighting"

# this is the original third party interface
# Documentation: https://aca.im/driver_docs/zencontrol/lighting_udp.pdf

class Zencontrol::ClassicTPI < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  generic_name :Lighting
  descriptive_name "Zencontrol Classic Lighting API"
  description "Uses the classic zencontrol third party interface UDP API"

  udp_port 5108

  default_settings({
    version:       1,
    controller_id: "ffffffffffff",
  })

  def on_load
    # Communication settings
    queue.wait = false
    on_update
  end

  BROADCAST = Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff]

  @version : UInt8 = 1_u8
  @controller : Bytes = BROADCAST

  def on_update
    @version = setting?(UInt8, :version) || 1_u8
    controller = setting?(String, :controller_id)

    if controller
      @controller = controller.rjust(12, '0').hexbytes
    else
      @controller = BROADCAST
    end
  end

  # Using indirect commands
  def trigger(area : UInt32, scene : UInt32)
    area = Area.new(area)
    set_lighting_scene(scene, area)
  end

  # Using direct command
  def light_level(area : UInt32, level : Float64)
    area = Area.new(area)
    set_lighting_level(level, area)
  end

  # ==================
  # Lighting Interface
  # ==================

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area = area.as(Area)
    scene = scene.clamp(0, 15) + 16
    area_id = area.id.as(UInt32).clamp(0, 127) + 128

    self[area.to_s] = scene
    do_send(area_id.to_u8, scene.to_u8)
  end

  def lighting_scene?(area : Area? = nil)
    self[area.to_s]? if area
  end

  LEVEL_PERCENTAGE = 0xFF / 100

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area = area.as(Area)

    # Levels are percentage based (on the PlaceOS side)
    level = level.clamp(0.0, 100.0)
    level_actual = (level * LEVEL_PERCENTAGE).round.to_u8
    area_id = area.id.as(UInt32).clamp(0, 127).to_u8

    self[area.append("level").to_s] = level
    do_send(area_id, level_actual)
  end

  def lighting_level?(area : Area? = nil)
    self[area.append("level").to_s]? if area
  end

  protected def do_send(address : UInt8, command : UInt8, **options)
    io = IO::Memory.new
    io.write_byte @version
    io.write @controller
    io.write_byte address
    io.write_byte command
    send(io.to_slice, **options)
  end

  def received(data, task)
    logger.debug { "Zencontrol sent: #{data.hexstring}" }
    task.try &.success
  end
end
