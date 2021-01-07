# TODO: figure out if I should use this
# require "placeos-driver/interface/muteable"

class Qsc::QSysRemote < PlaceOS::Driver
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1710
  descriptive_name "QSC Audio DSP"
  generic_name :Mixer

  @id : Int32 = 0
  @db_based_faders : Float64? = nil
  @integer_faders : Int32? = nil

  Delimiter = "\0"
  JsonRpcVer = "2.0"
  Errors = {
    -32700 => "Parse error. Invalid JSON was received by the server.",
    -32600 => "Invalid request. The JSON sent is not a valid Request object.",
    -32601 => "Method not found.",
    -32602 => "Invalid params.",
    -32603 => "Server error.",

    2 => "Invalid Page Request ID",
    3 => "Bad Page Request - could not create the requested Page Request",
    4 => "Missing file",
    5 => "Change Groups exhausted",
    6 => "Unknown change croup",
    7 => "Unknown component name",
    8 => "Unknown control",
    9 => "Illegal mixer channel index",
    10 => "Logon required"
}

  alias Num = Int32 | Float64
  alias NumTup = NamedTuple(Name: String, Value: Num)
  alias PosTup = NamedTuple(Name: String, Position: Num)
  alias Values = NumTup | PosTup | Array(NumTup) | Array(PosTup)
  alias Ids = String | Array(String)

  def on_load
    transport.tokenizer = Tokenizer.new(Delimiter)
    on_update
  end

  def on_update
    @db_based_faders = setting?(Float64, :db_based_faders)
    @integer_faders = setting?(Int32, :integer_faders)
  end

  def connected
    schedule.every(20.seconds) do
      logger.debug { "Maintaining Connection" }
      no_op
    end
    @id = 0
    logon
  end

  def disconnected
    schedule.clear
  end

  def no_op
    do_send(cmd: :NoOp, priority: 0)
  end

  def get_status
    do_send(next_id, cmd: :StatusGet, params: 0, priority: 0)
  end

  def logon(username : String? = nil, password : String? = nil)
    username ||= setting?(String, :username)
    password ||= setting?(String, :password)
    # Don't login if there is no username or password set
    return unless username || password

    do_send(
      cmd: :Logon,
      params: {
        :User => username,
        :Password => password
      },
      priority: 99
    )
  end

  def control_set(name : String, value : Num | Bool, ramp : Num? = nil, **options)
    if ramp
      params = {
        :Name =>  name,
        :Value => value,
        :Ramp => ramp
      } 
    else
      params = {
          :Name =>  name,
          :Value => value
      }
    end

    do_send(next_id, "Control.Set", params, **options)
  end

  def control_get(*names, **options)
    do_send(next_id, "Control.Get", names.to_a.flatten, **options)
  end

  # Example usage:
  # component_get 'My AMP', 'ent.xfade.gain', 'ent.xfade.gain2'
  def component_get(c_name : String, *controls, **options)
    do_send(next_id, "Component.Get", {
      :Name => c_name,
      :Controls => controls.to_a.flat_map { |ctrl| { :Name => ctrl } }
    }, **options)
  end

  # Example usage:
  # component_set 'My APM', { "Name" => 'ent.xfade.gain', "Value" => -100 }, {...}
  def component_set(c_name : String, values : Values, **options)
    values = ensure_array(values)

    do_send(next_id, "Component.Set", {
      :Name => c_name,
      :Controls => values
    }, **options)
  end

  def component_trigger(component : String, trigger : String, **options)
    do_send(next_id, "Component.Trigger", {
      :Name => component,
      :Controls => [{:Name => trigger}]
    }, **options)
  end

  def get_components(**options)
    do_send(next_id, "Component.GetComponents", **options)
  end

  def change_group_add_controls(group_id : Num, *controls, **options)
    do_send(next_id, "ChangeGroup.AddControl", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_remove_controls(group_id : Num, *controls, **options)
    do_send(next_id, "ChangeGroup.Remove", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_add_component(group_id : Num, component_name : String, *controls, **options)
    controls.to_a.flat_map { |ctrl| {:Name => ctrl } }

    do_send(next_id, "ChangeGroup.AddComponentControl", {
      :Id => group_id,
      :Component => {
        :Name => component_name,
        :Controls => controls
      }
    }, **options)
  end

  # Returns values for all the controls
  def poll_change_group(group_id : Num, **options)
    do_send(next_id, "ChangeGroup.Poll", {:Id => group_id}, **options)
  end

  # Removes the change group
  def destroy_change_group(group_id : Num, **options)
    do_send(next_id, "ChangeGroup.Destroy", {:Id => group_id}, **options)
  end

  # Removes all controls from change group
  def clear_change_group(group_id : Num, **options)
    do_send(next_id, "ChangeGroup.Clear", {:Id => group_id}, **options)
  end

  # Where every is the number of seconds between polls
  def auto_poll_change_group(group_id : Num, every : Num, **options)
    do_send(next_id, "ChangeGroup.AutoPoll", {
      :Id => group_id,
      :Rate => every
    }, **options)#, wait: false)
  end

  # Example usage:
  # mixer 'Parade', {1 => [2,3,4], 3 => 6}, true
  # def mixer(name, inouts, mute = false, *_,  **options)
  def mixer(name : String, inouts : Hash(Int32, Int32 | Array(Int32)), mute : Bool = false, **options)
    inouts.each do |input, outputs|
      outputs = ensure_array(outputs)

      do_send(next_id, "Mixer.SetCrossPointMute", {
          :Mixer => name,
          :Inputs => input.to_s,
          :Outputs => outputs.join(' '),
          :Value => mute
      }, **options)
    end
  end

  Faders = {
    matrix_in: {
      type: :"Mixer.SetInputGain",
      pri: :Inputs
    },
    matrix_out: {
      type: :"Mixer.SetOutputGain",
      pri: :Outputs
    },
    matrix_crosspoint: {
      type: :"Mixer.SetCrossPointGain",
      pri: :Inputs,
      sec: :Outputs
    }
  }
  def matrix_fader(name : String, level : Num, index : Array(Int32), type : String = "matrix_out", **options)
    info = Faders[type]

    if sec = info[:sec]?
      params = {
        :Mixer => name,
        :Value => level,
        info[:pri] => index[0],
        sec => index[1]
      }
    else
      params = {
        :Mixer => name,
        :Value => level,
        info[:pri] => index
      }
    end

    do_send(next_id, info[:type], params, **options)
  end

  Mutes = {
    matrix_in: {
      type: :"Mixer.SetInputMute",
      pri: :Inputs
    },
    matrix_out: {
      type: :"Mixer.SetOutputMute",
      pri: :Outputs
    }
  }
  def matrix_mute(name : String, value : Num, index : Array(Int32), type : String = "matrix_out", **options)
    info = Mutes[type]

    do_send(next_id, info[:type], {
      :Mixer => name,
      :Value => value,
      info[:pri] => index
    }, **options)
  end

  # value can either be a number to set actual numeric values like decibels
  # or Bool to deal with mute state
  def fader(fader_ids : Ids, value : Num | Bool, component : String? = nil, type : String = "fader", use_value : Bool = false, **options)
    faders = ensure_array(fader_ids)
    if component && (val = value.as?(Num))
      if @db_based_faders || use_value
        val = val / 10 if @integer_faders && !use_value
        fads = faders.map { |fad| {Name: fad, Value: val} }
      else
        val = val / 1000 if @integer_faders
        fads = faders.map { |fad| {Name: fad, Position: val} }
      end
      component_set(component, fads, name: "level_#{faders[0]}").get
      component_get(component, faders)
    else
      reqs = faders.map { |fad| control_set(fad, value) }
      reqs.last.get
      control_get(faders)
    end
  end

  def faders(ids : Ids, value : Num | Bool, component : String? = nil, type : String = "fader", **options)
    fader(ids, value, component, type, **options)
  end

  def mute(fader_id : Ids, state : Bool = true, component : String? = nil, type : String = "fader", **options)
    fader(fader_id, state, component, type, state, **options)
  end

  def mutes(ids : Ids, state : Bool = true, component : String? = nil, type : String = "fader", **options)
    mute(ids, state, component, type, **options)
  end

  def unmute(fader_id : Ids, component : String? = nil, type : String = "fader", **options)
    mute(fader_id, false, component, type, **options)
  end

  def query_fader(fader_id : Ids, component : String? = nil, type : String = "fader")
    faders = ensure_array(fader_id)
    component ? component_get(component, faders) : control_get(faders)
  end

  def query_faders(ids : Ids, component : String? = nil, type : String = "fader", **options)
    query_fader(ids, component, type, **options)
  end

  def query_mute(fader_id : Ids, component : String? = nil, type : String = "fader")
    query_fader(fader_id, component, type)
  end

  def query_mutes(ids : Ids, component : String? = nil, type : String = "fader", **options)
    query_fader(ids, component, type, **options)
  end

  def received(data, task)
    data = String.new(data)
    response = JSON.parse(data)

    logger.debug { "QSys sent:" }
    logger.debug { response }

    if err = response["error"]
      logger.warn { "Error code #{c = err["code"]} - #{Errors[c]}" }
      return task.try(&.abort(err["message"]))
    end

    case result = response["result"]
    when Hash
      if controls = result["Controls"]? # Probably Component.Get
        process(controls, name: result[:Name])
      elsif platform = result["Platform"]? # StatusGet
        self[:platform] = platform
        self[:state] = result["State"]
        self[:design_name] = result["DesignName"]
        self[:design_code] = result["DesignCode"]
        self[:is_redundant] = result["IsRedundant"]
        self[:is_emulator] = result["IsEmulator"]
        self[:status] = result["Status"]
      end
    when Array # Control.Get
      process(result)
    end

    task.try(&.success)
  end

  BoolVals = ["true", "false"]
  private def process(values, name = nil)
    component = name.present? ? "_#{name}" : ""
    values.each do |value|
      name = value["Name"]

      next unless val = value["Value"]?

      pos = value["Position"]
      str = value["String"]

      if BoolVals.include?(str)
        self["fader#{name}#{component}_mute"] = str == "true"
      else
        # Seems like string values can be independant of the other values
        # This should mostly work to detect a string value
        if val == 0 && pos == 0 && str[0] != '0'
          self["#{name}#{component}"] = str
          next
        end

        if pos
          # Float between 0 and 1
          self["fader#{name}#{component}"] = @integer_faders ? (pos * 1000).to_i : pos
        elsif val.is_a?(String)
          self["#{name}#{component}"] = val
        else
          self["fader#{name}#{component}"] = @integer_faders ? (val * 10).to_i : val
        end
      end
    end
  end

  def next_id
    @id += 1
    @id
  end

  private def do_send(id : Int32? = nil, cmd = nil, params = {} of String => String, **options)
    if id
      req = {
        id: id,
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    else
      req = {
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    end

    logger.debug { "requesting: #{req}" }

    cmd = req.to_json + Delimiter

    send(cmd, **options)
  end

  private def ensure_array(object)
    object.is_a?(Array) ? object : [object]
  end
end
