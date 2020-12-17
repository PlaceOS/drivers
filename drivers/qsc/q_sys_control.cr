# require "placeos-driver/interface/powerable"
# require "placeos-driver/interface/muteable"

class Qsc::QSysControl< PlaceOS::Driver
  # include Interface::Powerable
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1702
  descriptive_name "QSC Audio DSP External Control"
  generic_name :Mixer

  @username : String? = nil
  @password : String? = nil
  @change_group_id : Int32 = 30
  @em_id : Int32 = 0 # TODO: figure out suitable default
  alias Group = NamedTuple(id: Int32, controls: Set(Int32))
  @change_groups = {} of Symbol => Group
  @emergency_subscribe : PlaceOS::Driver::Subscriptions::Subscription? = nil

  def on_load
    on_update
  end

  def on_update
    @username = setting?(String, :username)
    @password = setting?(String, :password)

    em_id = setting?(Int32, :emergency)

    # Emergency ID changed
    if (e = @emergency_subscribe) && @em_id != em_id
      subscriptions.unsubscribe(e)
    end

    # Emergency ID exists
    if em_id
      group = create_change_group(:emergency)
      group_id = group[:id]
      controls = group[:controls]

      # Add id to change group as required
      unless controls.includes?(em_id)
        # subscribe to changes
        @em_id = em_id
        @emergency_subscribe = subscribe(em_id) do |_, value|
          self[:emergency] = value
        end

        @change_groups[:emergency] = {
          id: group_id,
          controls: Set.new([em_id])
        }
        send("cga #{group_id} #{em_id}\n", wait: false)
      end
    end
  end

  def connected
    login if @username

    @change_groups.each do |_, group|
      group_id = group[:id]
      controls = group[:controls]

      # Re-create change groups and poll every 2 seconds
      send("cgc #{group_id}\n", wait: false)
      send("cgsna #{group_id} 2000\n", wait: false)
      controls.each do |id|
        send("cga #{group_id} #{id}\n", wait: false)
      end
    end

    schedule.every(40.seconds) do
      logger.debug { "Maintaining Connection" }
      about
    end
  end

  def disconnected
    schedule.clear
  end

  def get_status(control_id : Int32, **options)
    send("cg #{control_id}\n", **options)
  end

  def set_position(control_id : Int32, position : Int32, ramp_time : Int32? = nil)
    if ramp_time
      send("cspr \"#{control_id}\" #{position} #{ramp_time}\n", wait: false)
      schedule.in(ramp_time.seconds + 200.milliseconds) { get_status(control_id) }
    else
      send("csp \"#{control_id}\" #{position}\n")
    end
  end

  def set_value(control_id : Int32, value : Int32, ramp_time : Int32? = nil, **options)
    if ramp_time
      send("csvr \"#{control_id}\" #{value} #{ramp_time}\n", **options, wait: false)
      schedule.in(ramp_time.seconds + 200.milliseconds) { get_status(control_id) }
    else
      send("csv \"#{control_id}\" #{value}\n", **options)
    end
  end

  def about
    send("sg\n", name: :status, priority: 0)
  end

  def login(username : String? = nil, password : String? = nil)
    username ||= @username
    password ||= @password
    send("login #{username} #{password}\n", name: :login, priority: 99)
  end

  private def create_change_group(name : Symbol) : Group
    group = @change_groups[name]?
    return group if group

    # Provide a unique group id
    next_id = @change_group_id
    @change_group_id += 1

    group = {
      id: next_id,
      controls: Set(Int32).new
    }
    @change_groups[name] = group

    # create change group and poll every 2 seconds
    send("cgc #{next_id}\n", wait: false)
    send("cgsna #{next_id} 2000\n", wait: false)
    group
  end

  def received(data, task)
    logger.debug { "received #{data}" }
  end

  private def do_send(data, **options)
    send(data, **options)
  end
end
