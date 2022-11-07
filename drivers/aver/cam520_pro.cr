require "placeos-driver"
require "placeos-driver/interface/camera"
require "./cam520_pro_models"

class Aver::Cam520Pro < PlaceOS::Driver
  include Interface::Camera

  # Discovery Information.
  generic_name :Camera
  descriptive_name "Aver 520 Pro Camera"

  # note: wss port is 9188
  uri_base "ws://10.110.144.40:9187/ws"

  default_settings({
    username: "admin",
    password: "Aver",

    zoom_max:        28448,
    invert_controls: false,
  })

  protected getter bearer_token : String = ""
  @zoom_max : Int32 = 28448

  def on_load
    queue.wait = false
    on_update
  end

  def on_update
    @zoom_max = setting(Int32, :zoom_max)
  end

  def connected
    send "token:#{authenticate}"
    schedule.clear
    schedule.every(10.minutes) { authenticate }
    schedule.every(1.minutes) { keep_alive }

    pan?
    tilt?
    zoom?
  end

  def disconnected
    schedule.clear
  end

  protected def check_success(response) : Bool
    return true if response.success?
    details = HttpResponse(Nil?).from_json(response.body.not_nil!)
    @bearer_token = "" if response.status_code == 401
    raise "unexpected response #{details.code} - #{details.msg}"
  end

  macro parse(response, klass = Nil?)
    check_success({{response}})
    HttpResponse({{klass}}).from_json({{response}}.body.not_nil!).data
  end

  protected def authenticate
    logger.debug { "Authenticating" }

    response = post("/login_name", body: {
      name:     setting(String, :username),
      password: setting(String, :password),
    }.to_json)

    @bearer_token = parse(response, Auth).token
  end

  def keep_alive
    send("alive")
  end

  getter pan_pos : Int32 = 0
  getter tilt_pos : Int32 = 0
  getter zoom_pos : Int32 = 0

  def received(data, task) : Nil
    data = String.new(data)
    logger.debug { "Camera sent: #{data}" }

    payload = Event.from_json(data).data
    case payload
    in Option
      value = payload.value.to_i
      case payload.option
      in .ptz_ps?
        @pan_pos = value
      in .ptz_ts?
        @tilt_pos = value
      in .ptz_zs?
        @zoom_pos = value
        self[:zoom] = value.to_f * (100.0 / @zoom_max.to_f)
      end
    in Event
      raise "not possible"
    end
  ensure
    task.try &.success
  end

  # ====== Camera Interface ======

  def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)
    if pan_speed >= tilt_speed
      axis = AxisSelect::Pan
      stop = AxisSelect::Tilt
      dir = pan_speed >= 0.0 ? 0 : 1
      cmd = pan_speed.zero? ? 2 : 1
    else
      stop = AxisSelect::Pan
      axis = AxisSelect::Tilt
      dir = tilt_speed >= 0.0 ? 0 : 1
      cmd = tilt_speed.zero? ? 2 : 1
    end

    # stop any previous move
    spawn(same_thread: true) do
      post("/camera_move", body: {
        method: "SetPtzf",
        axis:   stop.to_i,
        dir:    dir,
        cmd:    2,
      }.to_json)
    end

    Fiber.yield

    # start moving in the desired direction
    response = post("/camera_move", body: {
      method: "SetPtzf",
      axis:   axis.to_i,
      dir:    dir,
      cmd:    cmd,
    }.to_json)

    parse(response, Nil)
  end

  alias Presets = Hash(String, Tuple(Int32, Int32, Int32))
  @presets : Presets = {} of String => Tuple(Int32, Int32, Int32)

  def recall(position : String, index : Int32 | String = 0)
    if pos = @presets[position]?
      pan_pos, tilt_pos, zoom_pos = pos
      zoom_native(zoom_pos)
      pan_direct(pan_pos)
      tilt_direct(tilt_pos)
    else
      raise "unknown preset #{position}"
    end
  end

  def save_position(name : String, index : Int32 | String = 0)
    @presets[name] = {@pan_pos, @tilt_pos, @zoom_pos}
    save_presets
  end

  def remove_position(name : String, index : Int32 | String = 0)
    @presets.delete(name)
    save_presets
  end

  protected def save_presets
    define_setting(:camera_presets, @presets)
    self[:camera_presets] = @presets.keys
  end

  def pan_direct(position : Int32)
    response = post("/set_option", body: {
      method: "Set",
      option: "ptz_p",
      value:  position,
    }.to_json)

    parse(response, Nil) || position
  end

  def tilt_direct(position : Int32)
    response = post("/set_option", body: {
      method: "Set",
      option: "ptz_t",
      value:  position,
    }.to_json)

    parse(response, Nil) || position
  end

  def pan?
    response = post("/get_option", body: {
      method: "Get",
      option: "ptz_p_s",
    }.to_json)

    @pan_pos = parse(response, Int32)
  end

  def tilt?
    response = post("/get_option", body: {
      method: "Get",
      option: "ptz_t_s",
    }.to_json)

    @tilt_pos = parse(response, Int32)
  end

  # ====== Zoomable Interface ======

  # Zooms to an absolute position
  def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)
    position = position.clamp(0.0, 100.0)
    percentage = position / 100.0
    zoom_native (percentage * @zoom_max.to_f).to_i
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    case direction
    in .stop?
      dir = 0
      cmd = 2
    in .out?
      dir = 1
      cmd = 1
    in .in?
      dir = 0
      cmd = 1
    end

    response = post("/camera_move", body: {
      method: "SetPtzf",
      axis:   AxisSelect::Zoom.to_i,
      dir:    dir,
      cmd:    cmd,
    }.to_json)

    parse(response, Nil)
  end

  def zoom_native(position : Int32)
    response = post("/set_option", body: {
      method: "Set",
      option: "ptz_z",
      value:  position,
    }.to_json)

    parse(response, Nil) || position
  end

  def zoom? : Nil
    response = post("/get_option", body: {
      method: "Get",
      option: "ptz_z_s",
    }.to_json)

    @zoom_pos = value = parse(response, Int32)
    self[:zoom] = value.to_f * (100.0 / @zoom_max.to_f)
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

  # ====== Stoppable Interface ======

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    # tilt
    spawn(same_thread: true) do
      post("/camera_move", body: {
        method: "SetPtzf",
        axis:   AxisSelect::Tilt.to_i,
        dir:    0,
        cmd:    2,
      }.to_json)
    end

    # pan
    spawn(same_thread: true) do
      post("/camera_move", body: {
        method: "SetPtzf",
        axis:   AxisSelect::Pan.to_i,
        dir:    0,
        cmd:    2,
      }.to_json)
    end

    Fiber.yield

    # zoom
    response = post("/camera_move", body: {
      method: "SetPtzf",
      axis:   AxisSelect::Zoom.to_i,
      dir:    0,
      cmd:    2,
    }.to_json)

    parse(response, Nil)
  end
end
