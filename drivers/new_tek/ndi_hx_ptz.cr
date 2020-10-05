require "placeos-driver/interface/powerable"
require "placeos-driver/interface/camera"

module NewTek; end

module NewTek::NDI; end

class NewTek::NDI::HxPTZ < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Camera

  # Discovery Information
  generic_name :Camera
  descriptive_name "NewTek Camera NDI|HX PTZ Camera"
  uri_base "http://10.10.10.10"

  default_settings({
    invert_controls: false,
    presets:         {
      name: {pan: 1, tilt: 1, zoom: 1},
    },
    basic_auth: {
      username: "admin",
      password: "admin",
    },
  })

  def on_load
    # Configure the constants
    self[:has_discrete_zoom] = true

    schedule.every(60.seconds) { query_status }
    schedule.in(5.seconds) do
      query_status
      info?
    end

    # 5 seconds to zoom the entire range
    @zoom_range = 1..36
    @zoom_speed = 2
    @zoom = 1
    self[:zoom_range] = {min: @zoom_range.begin, max: @zoom_range.end}

    on_update
  end

  @invert_controls = false
  @presets = {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)

  def on_update
    self[:invert_controls] = @invert_controls = setting?(Bool, :invert_controls) || false
    @presets = setting?(Hash(String, Int32), :presets) || {} of String => Int32
    self[:presets] = @presets.keys
  end

  def power(state : Bool)
    param = state ? '1' : '0'
    action("/vb.htm?powermode=#{param}", name: "power") { self[:power] = state }
  end

  def power?
    action("/vb.htm?getpowermode") do |reponse|
      self[:power] = reponse.split("=")[1].strip == "1"
    end
  end

  # Temporary values until the camera is queried
  @moving = false
  @zooming = false
  @max_speed = 1

  # Implement Stoppable interface
  def stop(index : Int32 | String = 1, emergency : Bool = false)
    action("/vb.htm?ptstop=1",
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
    when MoveablePosition::Up, MoveablePosition::Down
      if @invert_controls && (position.up? || position.down?)
        position = position.up? ? MoveablePosition::Down : MoveablePosition::Up
      end

      action("/vb.htm?tilt#{position.to_s.downcase}start=1",
        name: "moving"
      ) { self[:moving] = @moving = true }
    when MoveablePosition::Left, MoveablePosition::Right
      action("/vb.htm?pan#{position.to_s.downcase}start=1",
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

  def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 1)
    # Ensure in range
    position = if @zoom_range.includes?(position)
                 position
               else
                 position < @zoom_range.begin ? @zoom_range.begin : @zoom_range.end
               end

    action("/vb.htm?zoompositionfromindex=#{position}",
      name: "zooming"
    ) { self[:zoom] = @zoom = position }
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 1)
    if direction.stop?
      action("/vb.htm?zoomstop=1",
        name: "zooming"
      ) do
        self[:zooming] = @zooming = false
      end
    else
      action("/vb.htm?zoom#{direction.to_s.downcase}start=1",
        name: "zooming"
      ) do
        self[:zooming] = @zooming = true
      end
    end
  end

  def home
    action("/vb.htm?ptzgotohome=1",
      name: "position"
    ) { }
  end

  def recall(position : String, index : Int32 | String = 1)
    if index = @presets[position]?
      action("/vb.htm?loadpreset=#{index}",
        name: "position"
      ) { }
    end
  end

  def save_position(name : String, index : Int32 | String = 1)
    # TODO:: pick an unused index
    preset_index = 0
    action("/vb.htm?savepreset=#{preset_index}",
      name: "position"
    ) do
      # TODO:: persist this to the database
      @presets[name] = preset_index
      self[:presets] = @presets.keys
    end
  end

  def delete_position(name : String, index : Int32 | String = 1)
    @presets.delete name
    # TODO:: persist this to the database
    self[:presets] = @presets.keys
  end

  def query_state
    queue(**opts) do |task|
      response = get("/ini.htm")
      raise "request error #{response.status_code}\n#{response.body}" unless response.success?
      body = response.body.not_nil!

      settings = {} of String => String
      results = body.split("\n").map(&.strip).each do |setting|
        parts = setting.split("=")
        settings[parts[0]] = parts[1]
      end

      if power = settings["powermode"]?
        self[:power] = power == "1"
      end

      if zoom = settings["zoomposition"]?
        self[:zoom] = zoom.to_i
      end

      if serial = settings["serialnum"]?
        self[:serial_number] = serial
      end

      if serial = settings["serialnum"]?
        self[:serial_number] = serial
      end

      if version = settings["softwareversion"]?
        self[:software_version] = version
      end

      if model = settings["model"]?
        self[:model] = model
      end

      if name = settings["cameraname"]?
        self[:camera_name] = name
      end

      task.success
    end
  end

  private def action(path, **opts, &block : HTTP::Client::Response -> _)
    queue(**opts) do |task|
      response = get(path)
      raise "request error #{response.status_code}\n#{response.body}" unless response.success?

      body = response.body
      raise "response error #{response.body}" unless body && body.starts_with?("OK")

      result = block.call(body)
      task.success result
    end
  end
end
