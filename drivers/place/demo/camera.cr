require "placeos-driver"
require "placeos-driver/interface/camera"
require "placeos-driver/interface/powerable"

class Place::Demo::Camera < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Camera

  # Discovery Information.
  generic_name :Camera
  descriptive_name "Demo Camera"
  udp_port 52381

  alias Presets = Hash(String, Tuple(Int32, Int32, Int32))
  @presets : Presets = {} of String => Tuple(Int32, Int32, Int32)

  def on_update
    @presets = setting?(Presets, :camera_presets) || @presets
    self[:presets] = @presets.keys
  end

  # ====== Powerable Interface ======

  def power(state : Bool)
    self[:power] = state
  end

  def power?
    case status?(Bool, :power)
    when true
      true
    when false
      false
    when nil
      self[:power] = false
    end
  end

  # ====== Camera Interface ======

  def home
    logger.debug { "camera moved to home" }
  end

  def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)
    if pan_speed.zero? && tilt_speed.zero?
      self[:moving] = false
    else
      self[:moving] = true
    end
  end

  # moves to an absolute position
  def pantilt(pan : Int32, tilt : Int32, speed : UInt8)
    logger.debug { "moved to position pan #{pan}, tilt #{tilt}" }
  end

  def recall(position : String, index : Int32 | String = 0)
    if pos = @presets[position]?
      pan_pos, tilt_pos, zoom_pos = pos
      pantilt(pan_pos, tilt_pos, 8_u8)
      zoom_to(zoom_pos)
    else
      raise "unknown preset #{position}"
    end
  end

  def save_position(name : String, index : Int32 | String = 0)
    @presets[name] = {1, 2, zoom?}
    save_presets
  end

  def remove_position(name : String, index : Int32 | String = 0)
    @presets.delete(name)
    save_presets
  end

  protected def save_presets
    define_setting(:camera_presets, @presets)
    self[:presets] = @presets.keys
  end

  # ====== Moveable Interface ======

  # moves at 50% of max speed
  def move(position : MoveablePosition, index : Int32 | String = 0)
    case position
    in .up?
      joystick(pan_speed: 0.0, tilt_speed: 50.0)
    in .down?
      joystick(pan_speed: 0.0, tilt_speed: -50.0)
    in .left?
      joystick(pan_speed: -50.0, tilt_speed: 0.0)
    in .right?
      joystick(pan_speed: 50.0, tilt_speed: 0.0)
    in .in?
      zoom(:in)
    in .out?
      zoom(:out)
    in .open?, .close?
      # not supported
    end
  end

  # ====== Zoomable Interface ======

  # Zooms to an absolute position
  def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)
    position = position.clamp(0.0, 100.0).to_i
    self[:zoom] = position
  end

  @zoom_task : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    @zoom_task.try &.cancel

    case direction
    in .in?
      self[:zooming] = true
      @zoom_task = schedule.every(250.milliseconds) do
        level = zoom? + 1
        level = level.clamp(0, 100)
        self[:zoom] = level

        if level == 100
          @zoom_task.try &.cancel
          @zoom_task = nil
        end
      end
    in .out?
      self[:zooming] = true
      @zoom_task = schedule.every(250.milliseconds) do
        level = zoom? - 1
        level = level.clamp(0, 100)
        self[:zoom] = level

        if level == 0
          @zoom_task.try &.cancel
          @zoom_task = nil
        end
      end
    in .stop?
      self[:zooming] = false
      @zoom_task = nil
    end
  end

  def zoom?
    case (zoom = status?(Int32, :zoom))
    in Int32
      zoom
    in Nil
      self[:zoom] = 0
    end
  end

  def pantilt?
    logger.debug { "query pantilt" }
  end

  # ====== Stoppable Interface ======

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    self[:moving] = false
  end

  # should be no incoming data
  def received(data, task, sequence : UInt32? = nil) : Nil
    logger.debug { "Camera sent: 0x#{data.hexstring}" }
    task.try &.success
  end
end
