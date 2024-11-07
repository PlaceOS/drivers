require "placeos-driver"
require "placeos-driver/interface/sensor"
require "placeos-driver/interface/lighting"

class KNX::Lighting < PlaceOS::Driver
  include Interface::Sensor
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  # Discovery Information
  descriptive_name "KNX Lighting"
  generic_name :Lighting

  default_settings({
    # these are optional but used to get feedback
    knx_scene_group:      "4/1/33",
    knx_brightness_group: "4/1/66",
    knx_brightness_max:   255,

    knx_motion: "1.8.110",

    # on and off switches like blinds
    switch_groups: {
      "Interactive Flat Blinds"      => "2/3/19",
      "Interactive Classroom Blinds" => "2/1/53",
    },
  })

  accessor knx : KNX_1

  def on_load
    on_update
  end

  def on_update
    @knx_motion = setting?(String, :knx_motion).presence
    @scene_group = setting?(String, :knx_scene_group).presence
    @brightness_group = setting?(String, :knx_brightness_group).presence
    @brightness_max = setting?(Int32, :knx_brightness_max) || 255
    @level_percentage = @brightness_max / 100

    @switch_groups = setting?(Hash(String, String), :switch_groups) || {} of String => String

    subscriptions.clear
    subscribe_datapoints
  end

  getter last_occupied : Int64 = 0_i64
  getter occupied : Bool = false
  getter knx_motion : String? = nil
  getter scene_group : String? = nil
  getter brightness_group : String? = nil
  getter brightness_max : Int32 = 255
  getter switch_groups : Hash(String, String) = {} of String => String
  @level_percentage : Float64 = 255.0 / 100.0

  protected def subscribe_datapoints
    if s_group = @scene_group
      knx.subscribe s_group do |_sub, payload|
        self[Area.new(component: s_group)] = data_to_int(String.from_json(payload))
      end
    end

    if b_group = @brightness_group
      knx.subscribe b_group do |_sub, payload|
        self[Area.new(component: b_group)] = data_scaled(String.from_json(payload))
      end
    end

    if motion = @knx_motion
      knx.subscribe motion do |_sub, payload|
        @last_occupied = Time.utc.to_unix
        @occupied = data_to_int(String.from_json(payload)) > 0
        self[:motion] = @occupied ? 1.0 : 0.0
      end

      schedule.clear
      schedule.every(10.seconds) { knx.status(motion) }
    end

    @switch_groups.each_value do |address|
      knx.subscribe address do |_sub, payload|
        # will return a payload like: %{"01"}
        self["switch_#{address}"] = payload[-2] == '1'
      end
    end
  end

  protected def data_to_int(hexstring : String) : Int32
    data = hexstring.rjust(8, '0').hexbytes
    IO::Memory.new(data).read_bytes(Int32, IO::ByteFormat::BigEndian)
  end

  protected def data_scaled(hexstring : String) : Float64
    data = hexstring.rjust(8, '0').hexbytes
    int = IO::Memory.new(data).read_bytes(Int32, IO::ByteFormat::BigEndian)
    (int.to_f / @brightness_max.to_f) * 100.0
  end

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area = area || Area.new(component: @scene_group)
    knx_address = area.component
    raise "no scene area / group address provided" unless knx_address

    knx.action(knx_address, scene)
  end

  def lighting_scene?(area : Area? = nil)
    if area
      address = area.component
      knx.status(address).get
      if hexstring = knx[address]?.try(&.as_s)
        # convert to integer and scale it into 0-100 range
        data_to_int(hexstring)
      end
    elsif knx_address = @scene_group
      self[Area.new(component: @scene_group)]?
    else
      raise "no brightness area / group address provided"
    end
  end

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area = area || Area.new(component: @brightness_group)
    knx_address = area.component
    raise "no brightness area / group address provided" unless knx_address

    level = level.clamp(0.0, 100.0)
    level_actual = (level * @level_percentage).round_away.to_i

    knx.action(knx_address, level_actual)
  end

  # return the current level
  def lighting_level?(area : Area? = nil)
    if area
      address = area.component
      knx.status(address).get
      if hexstring = knx[address]?.try(&.as_s)
        # convert to integer and scale it into 0-100 range
        data_scaled(hexstring)
      end
    elsif knx_address = @brightness_group
      self[Area.new(component: @brightness_group)]?
    else
      raise "no brightness area / group address provided"
    end
  end

  # helper for
  def switch(name : String, state : Bool)
    address = @switch_groups[name]? || name
    knx.action(address, state)
  end

  def switch_on(name : String)
    switch name, true
  end

  def switch_off(name : String)
    switch name, false
  end

  # ======================
  # Sensor interface
  # ======================

  SENSOR_TYPES = {SensorType::Presence}
  NO_MATCH     = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH unless @knx_motion
    return NO_MATCH if mac && mac != @knx_motion
    if type
      sensor_type = SensorType.parse(type)
      return NO_MATCH unless SENSOR_TYPES.includes?(sensor_type)
    end

    [get_sensor_details]
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless @knx_motion && @knx_motion == mac
    get_sensor_details
  end

  def get_sensor_details
    Detail.new(
      type: SensorType::Presence,
      value: @occupied ? 1.0 : 0.0,
      last_seen: @last_occupied,
      mac: @knx_motion.as(String),
      id: nil,
      name: "KNX motion sensor",
      module_id: module_id,
      binding: "motion",
    )
  end
end
