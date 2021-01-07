# TODO: figure out if I should use this
# require "placeos-driver/interface/muteable"

# https://q-syshelp.qsc.com/Content/External_Control/Q-SYS_External_Control/007_Q-SYS_External_Control_Protocol.htm

class Qsc::QSysRemote < PlaceOS::Driver
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1710
  descriptive_name "QSC Audio DSP"
  generic_name :Mixer

  @id : Int32 = 0

  Delimiter = "\0"
  JsonRpcVer = "2.0"

  alias Val = NamedTuple(Name: String, Value: Int32)
  alias Vals = Val | Array(Val)

  def on_load
    transport.tokenizer = Tokenizer.new(Delimiter)
    on_update
  end

  def on_update
    # @db_based_faders = setting(:db_based_faders)
    # @integer_faders = setting(:integer_faders)
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

  def control_set(name : String, value : Int32, ramp : Float64? = nil, **options)
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
  def component_get(name : String, *controls, **options)
    do_send(next_id, "Component.Get", {
      :Name => name,
      :Controls => controls.to_a.flat_map { |ctrl| { :Name => ctrl } }
    }, **options)
  end

  # Example usage:
  # component_set 'My APM', { "Name" => 'ent.xfade.gain', "Value" => -100 }, {...}
  def component_set(name : String, values : Vals, **options)
    values = values.is_a?(Array) ? values : [values]

    do_send(next_id, "Component.Set", {
      :Name => name,
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

  def change_group_add_controls(group_id : Int32, *controls, **options)
    do_send(next_id, "ChangeGroup.AddControl", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_remove_controls(group_id : Int32, *controls, **options)
    do_send(next_id, "ChangeGroup.Remove", {
      :Id => group_id,
      :Controls => controls
    }, **options)
  end

  def change_group_add_component(group_id : Int32, component_name : String, *controls, **options)
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
  def poll_change_group(group_id : Int32, **options)
    do_send(next_id, "ChangeGroup.Poll", {:Id => group_id}, **options)
  end

  # Removes the change group
  def destroy_change_group(group_id : Int32, **options)
    do_send(next_id, "ChangeGroup.Destroy", {:Id => group_id}, **options)
  end

  # Removes all controls from change group
  def clear_change_group(group_id : Int32, **options)
    do_send(next_id, "ChangeGroup.Clear", {:Id => group_id}, **options)
  end

  # Where every is the number of seconds between polls
  def auto_poll_change_group(group_id : Int32, every : Int32, **options)
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
      outs = outputs.is_a?(Array) ? outputs : [outputs]

      do_send(next_id, "Mixer.SetCrossPointMute", {
          :Mixer => name,
          :Inputs => input.to_s,
          :Outputs => outs.join(' '),
          :Value => mute
      }, **options)
    end
  end

  def received(data, task)
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
end
