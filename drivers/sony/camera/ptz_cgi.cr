require "placeos-driver"
require "placeos-driver/interface/camera"
require "placeos-driver/interface/powerable"

# Documentation: https://aca.im/driver_docs/Sony/sony-camera-CGI-Commands-1.pdf
# Sony PTZ Camera CGI Protocol Driver - Compatible with VISCA driver function names

class Sony::Camera::PtzCGI < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Camera

  # Discovery Information
  generic_name :Camera
  descriptive_name "Sony PTZ Camera HTTP CGI Protocol"
  uri_base "http://192.168.1.100"
  
  default_settings({
    basic_auth: {
      username: "admin",
      password: "Admin_1234",
    },
    max_pan_tilt_speed: 0x0F,
    zoom_speed:         0x07,
    zoom_max:           0x4000,
    camera_no:          0x01,
    invert_controls:    false,
    presets: {
      name: {pan: 1, tilt: 1, zoom: 1},
    },
  })

  enum Movement
    Idle
    Moving
    Unknown
  end

  def on_load
    # Configure the constants to match VISCA driver
    @pantilt_speed = -100..100
    self[:pan_speed] = self[:tilt_speed] = {min: -100, max: 100, stop: 0}
    self[:has_discrete_zoom] = true

    schedule.every(60.seconds) { query_status }
    schedule.in(5.seconds) do
      query_status
      info?
      # Only query power if device supports it
      spawn { power? } rescue nil
    end
    on_update
  end

  # Settings
  @max_pan_tilt_speed : UInt8 = 0x0F_u8
  @zoom_speed : UInt8 = 0x03_u8
  @zoom_max : UInt16 = 0x4000_u16
  @camera_address : UInt8 = 0x81_u8
  @invert_controls = false
  
  # State tracking - use consistent UInt16 types like VISCA driver
  alias Presets = Hash(String, Tuple(UInt16, UInt16, Float64))
  @presets : Presets = {} of String => Tuple(UInt16, UInt16, Float64)
  getter zoom_raw : UInt16 = 0_u16
  @zoom_pos : Float64 = 0.0
  getter tilt_pos : UInt16 = 0_u16
  getter pan_pos : UInt16 = 0_u16

  # CGI-specific state
  @moving = false
  @zooming = false
  @pan_range = 0..1
  @tilt_range = 0..1
  @zoom_range = 0..1

  def on_update
    @presets = setting?(Presets, :camera_presets) || @presets
    @max_pan_tilt_speed = setting?(UInt8, :max_pan_tilt_speed) || 0x0F_u8
    @zoom_speed = setting?(UInt8, :zoom_speed) || 0x03_u8
    @zoom_max = setting?(UInt16, :zoom_max) || 0x4000_u16
    @camera_address = 0x80_u8 | (setting?(UInt8, :camera_no) || 1_u8)
    
    self[:presets] = @presets.keys
    self[:inverted] = @invert_controls = setting?(Bool, :invert_controls) || false
  end

  # 24bit twos complement for CGI protocol
  private def twos_complement(value : Int32) : Int32
    # Handle 20-bit signed values (0xFFFFF mask)
    if value < 0
      # Convert negative to 20-bit two's complement
      ((~(-value) + 1) & 0xFFFFF)
    elsif (value & 0x80000) != 0
      # Convert 20-bit two's complement to negative
      -((~value + 1) & 0xFFFFF)
    else
      # Positive value, just mask to 20 bits
      value & 0xFFFFF
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
        state[parts[0]] = parts[1] if parts.size >= 2
      end

      result = block.call(state)
      task.success result
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
          pan_raw = twos_complement(parts[0].to_i(16))
          tilt_raw = twos_complement(parts[1].to_i(16))
          @zoom_raw = parts[2].to_i(16).to_u16
          
          # Update consistent position tracking
          @pan_pos = pan_raw.abs.clamp(0, UInt16::MAX).to_u16
          @tilt_pos = tilt_raw.abs.clamp(0, UInt16::MAX).to_u16
          
          self[:pan] = pan_raw
          self[:tilt] = tilt_raw
          
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
          parts = value.split(",")
          if parts.size >= 3
            movements = parts[0..2].map { |state| Movement.parse(state) }
            self[:moving] = @moving = movements.includes?(Movement::Moving)
          end

        when "PanTiltMaxVelocity"
          # PanTiltMaxVelocity=24
          # @max_speed = value.to_i(16)
        end
      end

      # Calculate zoom percentage based on zoom_max like VISCA driver
      self[:zoom] = @zoom_pos = @zoom_raw.to_f * (100.0 / @zoom_max.to_f)

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

  # ====== Powerable Interface ======
  # VISCA-compatible function names

  def power(state : Bool)
    logger.debug { "Setting power to #{state}" }
    # CGI implementation for power control
    power_cmd = state ? "on" : "standby"
    action("/command/camera.cgi?Power=#{power_cmd}",
      name: "power"
    ) do
      self[:power] = state
      state
    end
  end

  def power?
    query("/command/inquiry.cgi?inq=power", name: "power_query") do |response|
      power_state = response["Power"]? == "on"
      self[:power] = power_state
      power_state
    end
  end

  # ====== Camera Interface ======
  # VISCA-compatible function names

  def home
    logger.debug { "Moving camera to home position" }
    action("/command/presetposition.cgi?HomePos=ptz-recall",
      name: "position"
    ) { query_status }
  end

  def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)
    logger.debug { "Joystick movement: pan=#{pan_speed}, tilt=#{tilt_speed}" }
    # Convert index to camera index (0-based to 1-based)
    cam_index = index.to_i + 1
    
    # Apply invert controls - match VISCA driver pattern
    tilt_speed = -tilt_speed if @invert_controls

    # Convert speeds to appropriate range
    pan_speed = pan_speed.to_i.clamp(-100, 100)
    tilt_speed = tilt_speed.to_i.clamp(-100, 100)

    action("/command/ptzf.cgi?ContinuousPanTiltZoom=#{pan_speed.to_s(16)},#{tilt_speed.to_s(16)},0,image#{cam_index}",
      name: "moving"
    ) do
      self[:moving] = @moving = (pan_speed != 0 || tilt_speed != 0)
      
      # query the current position after we've stopped moving
      # query the current position after we've stopped moving - match VISCA pattern
      if pan_speed == 0 && tilt_speed == 0
        spawn do
          sleep 1.second
          pantilt?
        end
      end
      
      @moving
    end
  end

  # VISCA-compatible pantilt with UInt16 parameters
  def pantilt(pan : UInt16, tilt : UInt16, speed : UInt8)
    # Convert to CGI format
    pan_hex = pan.to_s(16)
    tilt_hex = tilt.to_s(16)
    
    action("/command/ptzf.cgi?AbsolutePanTilt=#{pan_hex},#{tilt_hex},#{speed.to_s(16)}",
      name: "position"
    ) do
      # Keep consistent state tracking
      @pan_pos = pan
      @tilt_pos = tilt
      self[:pan] = pan.to_i
      self[:tilt] = tilt.to_i
    end
  end

  # Additional pantilt method for CGI-style parameters
  def pantilt(pan : Int32, tilt : Int32, zoom : Int32? = nil) : Nil
    pan = pan.clamp(@pan_range.begin, @pan_range.end)
    tilt = tilt.clamp(@tilt_range.begin, @tilt_range.end)
    
    pan_comp = twos_complement(pan)
    tilt_comp = twos_complement(tilt)

    if zoom
      zoom = zoom.clamp(@zoom_range.begin, @zoom_range.end)
      zoom_comp = twos_complement(zoom)

      action("/command/ptzf.cgi?AbsolutePTZF=#{pan_comp.to_s(16)},#{tilt_comp.to_s(16)},#{zoom_comp.to_s(16)}",
        name: "position"
      ) do
        # Keep consistent state tracking
        @pan_pos = pan.abs.clamp(0, UInt16::MAX).to_u16
        @tilt_pos = tilt.abs.clamp(0, UInt16::MAX).to_u16
        @zoom_raw = zoom.not_nil!.to_u16
        
        self[:pan] = pan
        self[:tilt] = tilt
        self[:zoom] = zoom.not_nil!
      end
    else
      action("/command/ptzf.cgi?AbsolutePanTilt=#{pan_comp.to_s(16)},#{tilt_comp.to_s(16)},#{@max_pan_tilt_speed.to_s(16)}",
        name: "position"
      ) do
        # Keep consistent state tracking
        @pan_pos = pan.abs.clamp(0, UInt16::MAX).to_u16
        @tilt_pos = tilt.abs.clamp(0, UInt16::MAX).to_u16
        
        self[:pan] = pan
        self[:tilt] = tilt
      end
    end
  end

  def recall(position : String, index : Int32 | String = 0)
    if pos = @presets[position]?
      pan_pos, tilt_pos, zoom_pos = pos
      pantilt(pan_pos, tilt_pos, @max_pan_tilt_speed)
      zoom_to(zoom_pos)
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
    self[:presets] = @presets.keys
  end

  # ====== Moveable Interface ======
  # VISCA-compatible function names

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
  # VISCA-compatible function names

  def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)
    cam_index = index.to_i + 1

    position = position.clamp(0.0, 100.0)
    percentage = position / 100.0
    zoom_value = (percentage * @zoom_max.to_f).to_u16

    action("/command/ptzf.cgi?AbsoluteZoom=#{zoom_value.to_s(16)}",
      name: "zooming"
    ) do
      @zoom_raw = zoom_value
      self[:zoom] = @zoom_pos = position
    end
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    cam_index = index.to_i + 1

    if direction.stop?
      action("/command/ptzf.cgi?Move=stop,zoom,image#{cam_index}",
        priority: 999,
        name: "zooming"
      ) do 
        self[:zooming] = @zooming = false
        spawn { sleep 500.milliseconds; zoom? }
      end
    else
      action("/command/ptzf.cgi?Move=#{direction.out? ? "wide" : "near"},0,image#{cam_index}",
        name: "zooming"
      ) { self[:zooming] = @zooming = true }
    end
  end

  def zoom?
    query("/command/inquiry.cgi?inq=zoom", name: "zoom_query", priority: 0) do |response|
      if zoom_hex = response["AbsoluteZoom"]?
        @zoom_raw = zoom_hex.to_i(16).to_u16
        self[:zoom] = @zoom_pos = @zoom_raw.to_f * (100.0 / @zoom_max.to_f)
      end
      @zoom_pos
    end
  end

  def pantilt?
    query_status(priority: 0)
  end

  # ====== Stoppable Interface ======
  # VISCA-compatible function names

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    cam_index = index.to_i + 1

    action("/command/ptzf.cgi?Move=stop,motor,image#{cam_index}",
      priority: 999,
      name: "moving",
      clear_queue: emergency
    ) do
      self[:moving] = @moving = false
      query_status
    end
    
    # Stop zoom if moving - match VISCA behavior
    zoom(ZoomDirection::Stop, index) if @zooming
  end

  # ====== PTZ Auto Framing Function ======
  # Client-requested function from page 40 of documentation
  def ptzautoframing(enable : Bool = true, index : Int32 | String = 0)
    logger.debug { "Setting PTZ Auto Framing to #{enable}" }
    cam_index = index.to_i + 1
    command = enable ? "on" : "off"
    
    action("/command/ptzf.cgi?PTZAutoFraming=#{command},image#{cam_index}",
      name: "autoframing"
    ) do
      self[:ptz_auto_framing] = enable
      enable
    end
  end

  # Query auto framing status
  def ptzautoframing?
    query("/command/inquiry.cgi?inq=ptzautoframing", name: "autoframing_query") do |response|
      auto_framing = response["PTZAutoFraming"]? == "on"
      self[:ptz_auto_framing] = auto_framing
      auto_framing
    end
  end
end