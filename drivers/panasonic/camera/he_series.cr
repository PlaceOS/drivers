require "placeos-driver"
require "placeos-driver/interface/camera"
require "placeos-driver/interface/powerable"

# Documentation: https://aca.im/driver_docs/Panasonic/Camera%20Specifications%20V1.03E.pdf
# for a live view: http://<ip address>/cgi-bin/mjpeg?stream=1

class Panasonic::Camera::HESeries < PlaceOS::Driver
  include Interface::Camera
  include Interface::Powerable

  # Discovery Information
  generic_name :Camera
  descriptive_name "Panasonic PTZ Camera HE40/50/60"
  uri_base "http://192.168.0.12"

  default_settings({
    basic_auth: {
      username: "admin",
      password: "12345",
    },
    invert_controls: false,
    presets:         {
      name: {pan: 1, tilt: 1, zoom: 1},
    },
  })

  @pan : Int32 = 0
  @tilt : Int32 = 0
  @zoom_raw : Int32 = 0

  def on_load
    # delay between sending commands
    queue.delay = 130.milliseconds
    schedule.every(1.minute) { do_poll }
    on_update
  end

  @invert : Bool = false
  @default_movement_speed : Int32 = 12
  @presets = {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Float64)

  def on_update
    @default_movement_speed = setting?(Int32, :default_movement_speed) || 12
    self[:inverted] = @invert = setting?(Bool, :invert_controls) || false
    @presets = setting?(Hash(String, NamedTuple(pan: Int32, tilt: Int32, zoom: Float64)), :presets) || {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Float64)
    self[:presets] = @presets.keys
  end

  # ===================
  # Powerable interface

  def power(state : Bool)
    delay = 6.seconds if state
    request("O", state ? 1 : 0, delay: delay) { |resp| parse_power resp }
  end

  def power?
    parse_power query("O")
  end

  protected def parse_power(response : String)
    case response
    when "p0"       then self[:power] = false
    when "p1", "p3" then self[:power] = true
    end
  end

  # ================
  # Camera interface

  MOVEMENT_STOPPED = 50

  protected def joyspeed(speed : Float64)
    speed = speed.clamp(-100.0, 100.0)
    negative = speed < 0.0
    speed = speed.abs if negative

    percentage = speed / 100.0
    value = (percentage * 49.0).round.to_i
    value = -value if negative
    value
  end

  def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)
    tilt_speed = -tilt_speed if @invert

    pan = (MOVEMENT_STOPPED + joyspeed(pan_speed)).to_s.rjust(2, '0')
    tilt = (MOVEMENT_STOPPED + joyspeed(tilt_speed)).to_s.rjust(2, '0')

    # check if we want to stop panning
    if pan_speed == "50" && tilt_speed == "50"
      options = {
        retries:     4,
        priority:    queue.priority + 50,
        clear_queue: true,
        name:        :joystick,
      }
    else
      options = {
        retries:     1,
        priority:    queue.priority,
        clear_queue: false,
        name:        :joystick,
      }
    end

    request("PTS", "#{pan}#{tilt}", **options) do |resp|
      pan, tilt = resp[3..-1].scan(/.{2}/).flat_map(&.to_a)
      self[:pan_speed] = pan.not_nil!.to_i - MOVEMENT_STOPPED
      self[:tilt_speed] = tilt.not_nil!.to_i - MOVEMENT_STOPPED
    end
  end

  def recall(position : String, index : Int32 | String = 0)
    preset = @presets[position]?
    if preset
      pantilt preset[:pan], preset[:tilt]
      zoom_to preset[:zoom]
    else
      raise "unknown preset #{position}"
    end
  end

  def save_position(name : String, index : Int32 | String = 0)
    do_poll
    @presets[name] = {pan: @pan, tilt: @tilt, zoom: self[:zoom].as_f}
    define_setting(:presets, @presets)
    self[:presets] = @presets.keys
  end

  def remove_position(name : String, index : Int32 | String = 0)
    @presets.delete name
    define_setting(:presets, @presets)
    self[:presets] = @presets.keys
  end

  # ================
  # Moveable interface

  def move(position : MoveablePosition, index : Int32 | String = 0)
    case position
    in .open?, .close?
      # iris not supported
    in .down?, .up?
      joystick(
        pan_speed: 0,
        tilt_speed: position.down? ? @default_movement_speed : -@default_movement_speed
      )
    in .left?, .right?
      joystick(
        pan_speed: position.left? ? -@default_movement_speed : @default_movement_speed,
        tilt_speed: 0
      )
    in .in?, .out?
      zoom(position.in? ? ZoomDirection::In : ZoomDirection::Out)
    end
  end

  # ================
  # Zoomable interface

  ZOOM_MIN   = 0x555
  ZOOM_MAX   = 0xFFF
  ZOOM_RANGE = (ZOOM_MAX - ZOOM_MIN).to_f

  def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)
    position = position.clamp(0.0, 100.0)
    percentage = position / 100.0
    zoom_value = (percentage * ZOOM_RANGE).to_i + ZOOM_MIN # (zoom range is 0x555 => 0xFFF)

    request("AXZ", zoom_value.to_s(16).upcase.rjust(3, '0')) do |resp|
      self[:zoom] = resp[3..-1].to_i(16)
    end
  end

  def zoom?
    resp = query("GZ")
    if resp.includes?("--")
      message = "camera in standby, operation unavailable"
      logger.debug { message }
      message
    else
      @zoom_raw = resp[2..-1].to_i(16)
      self[:zoom] = (@zoom_raw - ZOOM_MIN).to_f * (100.0 / ZOOM_RANGE)
    end
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    case direction
    in .in?
      move_zoom(@default_movement_speed // 2)
    in .out?
      move_zoom(-@default_movement_speed)
    in .stop?
      move_zoom(0)
    end
  end

  protected def move_zoom(speed : Int32, **options)
    speed = MOVEMENT_STOPPED + speed
    request("Z", speed.to_s.rjust(2, '0'), **options) do |resp|
      self[:zoom_speed] = resp[2..-1].to_i - MOVEMENT_STOPPED
    end
  end

  # ================
  # Stoppable interface

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    move_zoom(0, priority: 100)
    joystick(0, 0)
  end

  # ======================
  # Other camera functions

  enum Installation
    Desk
    Ceiling
  end

  def installation(position : Installation)
    request("INS", position.desk? ? 0 : 1) { |resp| parse_installation resp }
  end

  def installation?
    parse_installation query("INS")
  end

  protected def parse_installation(response : String)
    case response
    when "ins0" then self[:installation] = Installation::Desk
    when "ins1" then self[:installation] = Installation::Ceiling
    end
  end

  def pantilt(pan : Int32, tilt : Int32)
    pan_val = pan.to_s(16).upcase.rjust(4, '0')
    tilt_val = tilt.to_s(16).upcase.rjust(4, '0')
    request("APC", "#{pan_val}#{tilt_val}", name: :pantilt) { |resp| parse_pantilt resp }
  end

  def pantilt?
    parse_pantilt query("APC")
  end

  protected def parse_pantilt(response : String)
    pan, tilt = response[3..-1].scan(/.{4}/).flat_map(&.to_a).compact_map(&.try &.to_i(16))
    self[:pan] = @pan = pan
    self[:tilt] = @tilt = tilt
  end

  def do_poll
    if power?
      zoom?
      pantilt?
    end
  end

  protected def request(cmd : String, data, **options, &callback : String -> _)
    request_string = "/cgi-bin/aw_ptz?cmd=%23#{cmd}#{data}&res=1"

    queue.add(**options) do |task|
      logger.debug { "requesting #{options[:name]?}: #{request_string}" }
      response = get(request_string)

      if response.success?
        body = response.body.downcase
        if body.starts_with?("er")
          case body[2]
          when '1' then task.abort("unsupported command #{cmd}: #{body}")
          when '2' then task.retry("camera busy, requested #{cmd}: #{body}")
          when '3' then task.abort("query outside acceptable range, requested #{cmd}: #{body}")
          end
        else
          begin
            logger.debug { "received: #{body}" }
            task.success callback.call(body)
          rescue error
            logger.error(exception: error) { "error processing response" }
            task.abort error.message
          end
        end
      else
        logger.error { "request failed with #{response.status_code}: #{response.body}" }
        task.abort "request failed"
      end
    end
  end

  protected def query(cmd : String)
    request_string = "/cgi-bin/aw_ptz?cmd=%23#{cmd}&res=1"
    logger.debug { "querying: #{request_string}" }
    response = get(request_string)
    raise "request failed with #{response.status_code}: #{response.body}" unless response.success?
    body = response.body.downcase
    if body.starts_with?("er")
      case body[2]
      when '1' then raise "unsupported command #{cmd}: #{body}"
      when '2' then raise "camera busy, requested #{cmd}: #{body}"
      when '3' then raise "query outside acceptable range, requested #{cmd}: #{body}"
      end
    end
    body
  end
end
