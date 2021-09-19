require "placeos-driver/interface/camera"
require "./xapi"

module Cisco::CollaborationEndpoint::Cameras
  include PlaceOS::Driver::Interface::Camera
  include Cisco::CollaborationEndpoint::XAPI

  alias Interface = PlaceOS::Driver::Interface

  protected def save_presets
    @ignore_update = true
    define_setting(:camera_presets, @presets)
    self[:camera_presets] = @presets.transform_values { |val| val.keys }
  end

  command({"Camera Preset Activate" => :camera_preset},
    preset_id: 1..35)
  command({"Camera Preset Store" => :camera_store_preset},
    camera_id: 1..1,
    preset_id: 1..35, # Optional - codec will auto-assign if omitted
    name_: String,
    take_snapshot_: Bool,
    default_position_: Bool)
  command({"Camera Preset Remove" => :camera_remove_preset},
    preset_id: 1..35)

  enum CameraAxis
    All
    Focus
    PanTilt
    Zoom
  end

  enum FocusDirection
    Far
    Near
    Stop
  end

  command({"Camera PositionReset" => :camera_position_reset},
    camera_id: 1..2,
    axis_: CameraAxis)
  command({"Camera Ramp" => :camera_move},
    camera_id: 1..2,
    pan_: Interface::Camera::PanDirection,
    pan_speed_: 1..15,
    tilt_: Interface::Camera::TiltDirection,
    tilt_speed_: 1..15,
    zoom_: Interface::Zoomable::ZoomDirection,
    zoom_speed_: 1..15,
    focus_: FocusDirection)

  # Camera Interface
  # ================

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    cam = index.to_i
    cam = 1 if index == 0

    camera_move(
      camera_id: cam,
      pan: PanDirection::Stop,
      tilt: TiltDirection::Stop,
      zoom: ZoomDirection::Stop
    )
  end

  def move(position : MoveablePosition, index : Int32 | String = 0)
    cam = index.to_i
    cam = 1 if index == 0

    case position
    in .open?, .close?
      # iris not supported
    in .down?, .up?
      joystick(
        pan_speed: 0,
        tilt_speed: position.down? ? -6 : 6,
        index: cam
      )
    in .left?, .right?
      joystick(
        pan_speed: position.left? ? -6 : 6,
        tilt_speed: 0,
        index: cam
      )
    in .in?, .out?
      zoom(position.in? ? ZoomDirection::In : ZoomDirection::Out, cam)
    end
  end

  def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 0)
    raise "direct zoom unsupported on this camera"
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    cam = index.to_i
    cam = 1 if index == 0

    camera_move(
      camera_id: cam,
      zoom: direction,
      zoom_speed: 6
    )
  end

  # @pan_range = -15..15
  # @tilt_range = -15..1

  def joystick(pan_speed : Int32, tilt_speed : Int32, index : Int32 | String = 0)
    pan = if pan_speed == 0
            pan_speed = nil
            PanDirection::Stop
          else
            pan_speed < 0 ? PanDirection::Left : PanDirection::Right
          end

    tilt = if tilt_speed == 0
             tilt_speed = nil
             TiltDirection::Stop
           else
             tilt_speed < 0 ? TiltDirection::Down : TiltDirection::Up
           end

    cam = index.to_i
    cam = 1 if index == 0

    camera_move(
      camera_id: cam,
      pan: pan,
      pan_speed: pan_speed.try &.abs,
      tilt: tilt,
      tilt_speed: tilt_speed.try &.abs,
      zoom: ZoomDirection::Stop
    )
  end

  def recall(position : String, index : Int32 | String = 0)
    cam = index.to_i
    cam = 1 if index == 0

    presets = @presets[cam]? || {} of String => Int32
    preset = presets[position]?
    raise "preset '#{position}' not found on camera #{index}" unless preset

    camera_preset(preset_id: preset)
  end

  def save_position(name : String, index : Int32 | String = 0)
    cam = index.to_i
    cam = 1 if index == 0

    presets = @presets[cam]? || {} of String => Int32
    in_use = @presets.values.flat_map(&.values)
    next_available = ((1..35).to_a - in_use).first
    presets[name] = next_available

    camera_store_preset(
      camera_id: cam,
      preset_id: next_available, # Optional - codec will auto-assign if omitted
      name: name
    ).get

    @presets[cam] = presets
    save_presets
    true
  end

  def remove_position(name : String, index : Int32 | String = 0)
    cam = index.to_i
    cam = 1 if index == 0

    presets = @presets[cam]? || {} of String => Int32
    presets.delete(name)
    if presets.empty?
      @presets.delete(cam)
    else
      @presets[cam] = presets
    end
    save_presets
    true
  end
end
