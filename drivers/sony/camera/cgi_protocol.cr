require "placeos-driver/interface/camera"

module Sony; end

module Sony::Camera; end

# Documentation: https://aca.im/driver_docs/Sony/sony-camera-CGI-Commands-1.pdf

class Sony::Camera::CGI < PlaceOS::Driver
  # include Interface::Powerable
  include Interface::Camera

  # Discovery Information
  generic_name :Camera
  descriptive_name "Sony Camera HTTP CGI Protocol"

  default_settings({
    basic_auth: {
      username: "admin",
      password: "Admin_1234",
    },
    invert_controls: false,
    presets:         {
      name: {pan: 1, tilt: 1, zoom: 1},
    },
  })

  enum Movement
    Idle
    Moving
    Unknown
  end

  def on_load
    # Configure the constants
    @pantilt_speed = -100..100
    self[:pan_speed] = self[:tilt_speed] = {min: -100, max: 100, stop: 0}
    self[:has_discrete_zoom] = true

    schedule.every(60.seconds) { query_status }
    schedule.in(5.seconds) do
      query_status
      info?
    end
    on_update
  end

  @invert_controls = false
  @presets = {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)

  def on_update
    self[:invert_controls] = @invert_controls = setting?(Bool, :invert_controls) || false
    @presets = setting?(Hash(String, NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)), :presets) || {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)
    self[:presets] = @presets.keys
  end

  # 24bit twos complement
  private def twos_complement(value)
    if value > 0
      value > 0x80000 ? -(((~(value & 0xFFFFF)) + 1) & 0xFFFFF) : value
    else
      ((~(-value & 0xFFFFF)) + 1) & 0xFFFFF
    end
  end

  private def query(path, **opts, &block : Hash(String, String) -> _)
    queue(**opts) do |task|
      response = get(path)
      data = response.body.not_nil!

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?

      # convert data into more consumable state
      state = {} of String => String
      data.split("&").each do |key_value|
        parts = key_value.strip.split("=")
        state[parts[0]] = parts[1]
      end

      result = block.call(state)
      task.success result
    end
  end

  # Temporary values until the camera is queried
  @moving = false
  @zooming = false
  @max_speed = 1

  def query_status(priority : Int32 = 0)
    # Response looks like:
    # AbsolutePTZF=15400,fd578,0000,cbde&PanMovementRange=eac00,15400
    query("/command/inquiry.cgi?inq=ptzf", priority: priority) do |response|
      # load the current state
      response.each do |key, value|
        case key
        when "AbsolutePTZF"
          #              Pan,  Tilt, Zoom,Focus
          # AbsolutePTZF=15400,fd578,0000,ca52
          parts = value.split(",")
          self[:pan] = @pan = twos_complement parts[0].to_i(16)
          self[:tilt] = @tilt = twos_complement parts[1].to_i(16)
          self[:zoom] = @zoom = parts[2].to_i(16)
        when "PanMovementRange"
          # PanMovementRange=eac00,15400
          parts = value.split(",")
          pan_min = twos_complement parts[0].to_i(16)
          pan_max = twos_complement parts[1].to_i(16)
          @pan_range = pan_min..pan_max
          self[:pan_range] = {min: pan_min, max: pan_max}
        when "TiltMovementRange"
          # TiltMovementRange=fc400,b400
          parts = value.split(",")
          tilt_min = twos_complement parts[0].to_i(16)
          tilt_max = twos_complement parts[1].to_i(16)
          @tilt_range = tilt_min..tilt_max
          self[:tilt_range] = {min: tilt_min, max: tilt_max}
        when "ZoomMovementRange"
          #                    min, max, digital
          # ZoomMovementRange=0000,4000,7ac0
          parts = value.split(",")
          zoom_min = parts[0].to_i(16)
          zoom_max = parts[1].to_i(16)
          @zoom_range = zoom_min..zoom_max
          self[:zoom_range] = {min: zoom_min, max: zoom_max}
        when "PtzfStatus"
          # PtzfStatus=idle,idle,idle,idle
          parts = value.split(",").map { |state| Movement.parse(state) }[0..2]
          self[:moving] = @moving = parts.includes?(Movement::Moving)

          # when "AbsoluteZoom"
          #  # AbsoluteZoom=609
          #  self[:zoom] = @zoom = value.to_i(16)

          # NOTE:: These are not required as speeds are scaled
          #
          # when "ZoomMaxVelocity"
          #  # ZoomMaxVelocity=8
          #  @zoom_speed = 1..value.to_i(16)

        when "PanTiltMaxVelocity"
          # PanTiltMaxVelocity=24
          @max_speed = value.to_i(16)
        end
      end

      response
    end
  end

  def info?
    query("/command/inquiry.cgi?inq=system", priority: 0) do |response|
      response.each do |key, value|
        if {"ModelName", "Serial", "SoftVersion", "ModelForm", "CGIVersion"}.includes?(key)
          self[key.underscore] = value
        end
      end
      response
    end
  end

  private def action(path, **opts, &block : HTTP::Client::Response -> _)
    queue(**opts) do |task|
      response = get(path)
      raise "request error #{response.status_code}\n#{response.body}" unless response.success?

      result = block.call(response)
      task.success result
    end
  end

  # Implement Stoppable interface
  def stop(index : Int32 | String = 1, emergency : Bool = false)
    action("/command/ptzf.cgi?Move=stop,motor,image#{index}",
      priority: 999,
      name: "moving",
      clear_queue: emergency
    ) do
      zoom ZoomDirection::Stop if @zooming
      self[:moving] = @moving = false
      query_status
    end
  end

  # Implement Moveable interface
  def move(position : MoveablePosition, index : Int32 | String = 1)
    case position
    when MoveablePosition::Up, MoveablePosition::Down,
         MoveablePosition::Left, MoveablePosition::Right
      # Tilt, Pan
      if @invert_controls && (position.up? || position.down?)
        position = position.up? ? MoveablePosition::Down : MoveablePosition::Up
      end

      action("/command/ptzf.cgi?Move=#{position.to_s.downcase},0,image#{index}",
        name: "moving"
      ) { self[:moving] = @moving = true }
    when MoveablePosition::In
      zoom ZoomDirection::In
    when MoveablePosition::Out
      zoom ZoomDirection::Out
    else
      raise "unsupported direction: #{position}"
    end
  end

  macro in_range(range, value)
    {{value}} = if {{range}}.includes? {{value}}
                  {{value}}
                else
                  {{value}} < {{range}}.begin ? {{range}}.begin : {{range}}.end
                end
    {{value}} = twos_complement({{value}})
  end

  def pantilt(pan : Int32, tilt : Int32, zoom : Int32? = nil) : Nil
    in_range @pan_range, pan
    in_range @tilt_range, tilt

    if zoom
      in_range @zoom_range, zoom

      action("/command/ptzf.cgi?AbsolutePTZF=#{pan.to_s(16)},#{tilt.to_s(16)},#{zoom.to_s(16)}",
        name: "position"
      ) do
        self[:pan] = @pan = pan
        self[:tilt] = @tilt = tilt
        self[:zoom] = @zoom = zoom.not_nil!
      end
    else
      action("/command/ptzf.cgi?AbsolutePanTilt=#{pan.to_s(16)},#{tilt.to_s(16)},#{@max_speed.to_s(16)}",
        name: "position"
      ) do
        self[:pan] = @pan = pan
        self[:tilt] = @tilt = tilt
      end
    end
  end

  # Implement Camera interface
  def joystick(pan_speed : Int32, tilt_speed : Int32, index : Int32 | String = 1)
    range = -100..100
    in_range range, pan_speed
    in_range range, tilt_speed

    tilt_speed = -tilt_speed if @invert_controls && tilt_speed != 0

    action("/command/ptzf.cgi?ContinuousPanTiltZoom=#{pan_speed.to_s(16)},#{tilt_speed.to_s(16)},0,image#{index}",
      name: "moving"
    ) do
      self[:moving] = @moving = (pan_speed != 0 || tilt_speed != 0)
      query_status if !@moving
      @moving
    end
  end

  def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 1)
    in_range @zoom_range, position
    action("/command/ptzf.cgi?AbsoluteZoom=#{position.to_s(16)}",
      name: "zooming"
    ) { self[:zoom] = @zoom = position }
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 1)
    if direction.stop?
      action("/command/ptzf.cgi?Move=stop,zoom,image#{index}",
        priority: 999,
        name: "zooming"
      ) { self[:zooming] = @zooming = false }
    else
      action("/command/ptzf.cgi?Move=#{direction.out? ? "wide" : "near"},0,image#{index}",
        name: "zooming"
      ) { self[:zooming] = @zooming = true }
    end
  end

  def home
    action("/command/presetposition.cgi?HomePos=ptz-recall",
      name: "position"
    ) { query_status }
  end

  def recall(position : String, index : Int32 | String = 1)
    preset = @presets[position]?
    if preset
      pantilt **preset
    else
      raise "unknown preset #{position}"
    end
  end

  def save_position(name : String, index : Int32 | String = 1)
    @presets[name] = {
      pan: @pan, tilt: @tilt, zoom: @zoom,
    }
    # TODO:: persist this to the database
    self[:presets] = @presets.keys
  end

  def delete_position(name : String, index : Int32 | String = 1)
    @presets.delete name
    # TODO:: persist this to the database
    self[:presets] = @presets.keys
  end
end
