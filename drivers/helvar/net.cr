require "placeos-driver"
require "placeos-driver/interface/lighting"

# Documentation: https://aca.im/driver_docs/Helvar/HelvarNet-Overview.pdf

class Helvar::Net < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  # Discovery Information
  tcp_port 50000
  descriptive_name "Helvar Net Lighting Gateway"
  generic_name :Lighting

  default_settings({
    version:       2,
    ignore_blocks: true,
    poll_group:    nil,
  })

  def on_load
    transport.tokenizer = Tokenizer.new("#")
    on_update
  end

  def on_update
    @version = setting?(Int32, :version) || 2
    @ignore_blocks = setting?(Bool, :ignore_blocks) || true
    @poll_group = setting?(Int32, :poll_group)
  end

  @poll_group : Int32?

  def connected
    schedule.every(40.seconds) do
      logger.debug { "-- Polling Helvar" }
      if poll_group = @poll_group
        get_current_preset poll_group
      else
        query_software_version
      end
    end
  end

  def disconnected
    schedule.clear
  end

  def lighting(group : Int32, state : Bool)
    level = state ? 100 : 0
    light_level(group, level)
  end

  def light_level(group : Int32, level : Int32, fade : Int32 = 1000)
    fade = (fade / 10).to_i
    self["area#{group}_level"] = level
    group_level(group: group, level: level, fade: fade, name: "group_level#{group}")
  end

  def trigger(group : Int32, scene : Int32, fade : Int32 = 1000)
    fade = (fade / 10).to_i
    self["area#{group}"] = scene
    group_scene(group: group, scene: scene, fade: fade, name: "group_scene#{group}")
  end

  def get_current_preset(group : Int32)
    query_last_scene(group: group, name: "query_scene#{group}")
  end

  def query_scene_levels(group : Int32)
    query_scene_info(group: group, name: "query_scene#{group}_info")
  end

  CMD_METHODS = {
    group_scene:                    11,
    device_scene:                   12,
    group_level:                    13,
    device_level:                   14,
    group_proportion:               15,
    device_proportion:              16,
    group_modify_proportion:        17,
    device_modify_proportion:       18,
    group_emergency_test:           19,
    device_emergency_test:          20,
    group_emergency_duration_test:  21,
    device_emergency_duration_test: 22,
    group_emergency_stop:           23,
    device_emergency_stop:          24,

    # Query commands
    query_lamp_hours:                  70,
    query_ballast_hours:               71,
    query_max_voltage:                 72,
    query_min_voltage:                 73,
    query_max_temp:                    74,
    query_min_temp:                    75,
    query_device_types_with_addresses: 100,
    query_clusters:                    101,
    query_routers:                     102,
    query_LSIB:                        103,
    query_device_type:                 104,
    query_description_group:           105,
    query_description_device:          106,
    query_workgroup_name:              107, # must use UDP
    query_workgroup_membership:        108,
    query_last_scene:                  109,
    query_device_state:                110,
    query_device_disabled:             111,
    query_lamp_failure:                112,
    query_device_faulty:               113,
    query_missing:                     114,
    query_emergency_battery_failure:   129,
    query_measurement:                 150,
    query_inputs:                      151,
    query_load:                        152,
    query_power_consumption:           160,
    query_group_power_consumption:     161,
    query_group:                       164,
    query_groups:                      165,
    query_scene_names:                 166,
    query_scene_info:                  167,
    query_emergency_func_test_time:    170,
    query_emergency_func_test_state:   171,
    query_emergency_duration_time:     172,
    query_emergency_duration_state:    173,
    query_emergency_battery_charge:    174,
    query_emergency_battery_time:      175,
    query_emergency_total_lamp_time:   176,
    query_time:                        185,
    query_longitude:                   186,
    query_latitude:                    187,
    query_time_zone:                   188,
    query_daylight_savings:            189,
    query_software_version:            190,
    query_helvar_net:                  191,
  }

  # Dynamically define methods based on the tuple above
  {% for name, command in CMD_METHODS %}
    def {{name.id}}(group : Int32? = nil, block : Int32? = nil, level : Int32? = nil, scene : Int32? = nil, fade : Int32? = nil, addr : Int32? = nil, **options)
      do_send({{command.id.stringify}}, @version, group, block, level, scene, fade, addr, **options)
    end
  {% end %}

  # Generate a String => String hash based on the data above
  macro build_command_hash
    COMMANDS = {
      {% for name, command in CMD_METHODS %}
        {{name.id.stringify}} => {{command.id.stringify}},
      {% end %}
    }
    COMMANDS.merge!(COMMANDS.invert)
  end

  build_command_hash

  PARAMS = {
    "V" => :ver,
    "Q" => :seq,
    "C" => :cmd,
    "A" => :ack,
    "@" => :addr,
    "F" => :fade,
    "T" => :time,
    "L" => :level,
    "G" => :group,
    "S" => :scene,
    "B" => :block,
    "N" => :latitude,
    "E" => :longitude,
    "Z" => :time_zone,
    # brighter or dimmer than the current level by a % of the difference
    "P" => :proportion,
    "D" => :display_screen,
    "Y" => :daylight_savings,
    "O" => :force_store_scene,
    "K" => :constant_light_scene,
  }

  def received(data, task)
    data = String.new(data)
    logger.debug { "Helvar sent: #{data}" }
    task_name = task.try(&.name)

    # Remove the # at the end of the message
    data = data[0..-2]

    # Group level changed: ?V:2,C:109,G:12706=13 (query scene response)
    # Update pushed >V:2,C:11,G:25007,B:1,S:13,F:100 (current scene level)

    # Remove junk data (when whitelisting gateway is in place)
    start_of_message = data.index(/[\?\>\!]V:/i)
    if start_of_message != 0
      logger.warn { "Lighting error response: #{data[0...start_of_message]}" }
      data = data[start_of_message..-1]
    end

    # remove connectors from multi-part responses
    data = data.delete("$")

    indicator = data[0]
    case indicator
    when '?', '>'
      # remove indicator
      data = data[1..-1]

      # check if this is a result
      parts = data.split("=")
      data = parts[0]
      value = parts[1]?

      # Extract components of the message
      params = {} of Symbol => String
      data.split(",").each do |param|
        parts = param.split(":")
        if parts.size > 1
          params[PARAMS[parts[0]]] = parts[1]
        elsif parts[0][0] == '@'
          params[:addr] == parts[0][1..-1]
        else
          logger.debug { "unknown param type #{param}" }
        end
      end

      # Check for :ack
      ack = params[:ack]?
      if ack
        return task.try &.abort("request failed") if ack != "1"
        return task.try &.success
      end

      cmd = COMMANDS[params[:cmd]]
      case cmd
      when "query_last_scene"
        scene = value.try &.to_i
        group = params[:group]
        self["area#{group}"] = scene
        task.not_nil!.success(scene) if task_name == "query_scene#{group}"
      when "group_scene"
        block = params[:block]
        group = params[:group]
        scene = params[:scene].to_i
        if block
          if @ignore_blocks
            self["area#{group}"] = scene
          else
            self["area#{group}_#{block}"] = scene
          end
        else
          self["area#{group}"] = scene
        end
        task.not_nil!.success(scene) if task_name == "group_scene#{group}"
      when "group_level"
        task.not_nil!.success if task_name == "group_level#{params[:group]}"
      when "query_scene_info"
        group = params[:group]
        if value && task_name == "query_scene#{group}_info"
          levels = value.split(",L")[0].split(',').map(&.to_i)
          task.not_nil!.success(levels)
        end
      else
        logger.debug { "unknown response value\n#{cmd} = #{value}" }
      end
    when '!'
      error = ERRORS[data.split("=")[1]]
      error = "#{error} for #{data}"
      self[:last_error] = error
      logger.warn { error }
      return task.try &.abort(error)
    else
      logger.info { "unknown request #{data}" }
    end

    task.try(&.success) unless task_name
  end

  ERRORS = {
    "0"  => "success",
    "1"  => "invalid group index parameter",
    "2"  => "invalid cluster parameter",
    "3"  => "invalid router",
    "4"  => "invalid router subnet",
    "5"  => "invalid device parameter",
    "6"  => "invalid sub device parameter",
    "7"  => "invalid block parameter",
    "8"  => "invalid scene",
    "9"  => "cluster does not exist",
    "10" => "router does not exist",
    "11" => "device does not exist",
    "12" => "property does not exist",
    "13" => "invalid RAW message size",
    "14" => "invalid messages type",
    "15" => "invalid message command",
    "16" => "missing ASCII terminator",
    "17" => "missing ASCII parameter",
    "18" => "incompatible version",
  }

  protected def do_send(cmd : String, ver = @version, group = nil, block = nil, level = nil, scene = nil, fade = nil, addr = nil, **options)
    req = String.build do |str|
      str << ">V:" << ver << ",C:" << cmd
      str << ",G:" << group if group
      str << ",B:" << block if block
      str << ",L:" << level if level
      str << ",S:" << scene if scene
      str << ",F:" << fade if fade
      str << ",@:" << addr if addr
      str << "#"
    end
    logger.debug { "Requesting helvar: #{req}" }
    send(req, **options)
  end

  # ==================
  # Lighting Interface
  # ==================
  protected def check_arguments(area : Area?)
    area_id = area.try(&.id)
    raise ArgumentError.new("area.id required (helvar group)") unless area_id
    area_id.to_i
  end

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    trigger(check_arguments(area), scene.to_i, fade_time.to_i)
  end

  def lighting_scene?(area : Area? = nil)
    get_current_preset check_arguments(area)
  end

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area_id = check_arguments area
    light_level(area_id, level.round_even.to_i, fade_time.to_i)
  end

  def lighting_level?(area : Area? = nil)
    group = check_arguments area
    if scene = get_current_preset(group).get(response_required: true).payload.to_i
      payload = query_scene_levels(group).get(response_required: true).payload
      levels = Array(Int32).from_json(payload)
      self["area#{group}_level"] = levels[scene]
    end
  end
end
