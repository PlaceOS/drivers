# require "placeos-driver/interface/muteable"

class Qsc::QSysControl< PlaceOS::Driver
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1702
  descriptive_name "QSC Audio DSP External Control"
  generic_name :Mixer

  alias Group = NamedTuple(id: Int32, controls: Set(Int32))
  alias Ids = Int32 | Array(Int32)
  alias Val = Int32 | Float64

  @username : String? = nil
  @password : String? = nil
  @change_group_id : Int32 = 30
  @em_id : Int32 = 0 # TODO: figure out suitable default
  @emergency_subscribe : PlaceOS::Driver::Subscriptions::Subscription? = nil
  @change_groups = {} of Symbol => Group

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

        update_change_group(:emergency, group_id, Set.new([em_id]))
        do_send("cga #{group_id} #{em_id}\n", wait: false)
      end
    end
  end

  def connected
    login if @username

    @change_groups.each do |_, group|
      group_id = group[:id]
      controls = group[:controls]

      # Re-create change groups and poll every 2 seconds
      do_send("cgc #{group_id}\n", wait: false)
      do_send("cgsna #{group_id} 2000\n", wait: false)
      controls.each do |id|
        do_send("cga #{group_id} #{id}\n", wait: false)
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
    do_send("cg #{control_id}\n", **options)
  end

  def set_position(control_id : Int32, position : Int32, ramp_time : Val? = nil)
    if ramp_time
      do_send("cspr \"#{control_id}\" #{position} #{ramp_time}\n", wait: false)
      schedule.in(ramp_time.seconds + 200.milliseconds) { get_status(control_id) }
    else
      do_send("csp \"#{control_id}\" #{position}\n")
    end
  end

  def set_value(control_id : Int32, value : Val, ramp_time : Val? = nil, **options)
    if ramp_time
      do_send("csvr \"#{control_id}\" #{value} #{ramp_time}\n", **options, wait: false)
      schedule.in(ramp_time.seconds + 200.milliseconds) { get_status(control_id) }
    else
      do_send("csv \"#{control_id}\" #{value}\n", **options)
    end
  end

  def about
    do_send("sg\n", name: :status, priority: 0)
  end

  def login(username : String? = nil, password : String? = nil)
    username ||= @username
    password ||= @password
    do_send("login #{username} #{password}\n", name: :login, priority: 99)
  end

  # Used to set a dial number/string
  def set_string(control_ids : Ids, text : String)
    ensure_array(control_ids).each do |id|
      do_send("css \"#{id}\" \"#{text}\"\n").get
      self[id] = text
    end
  end

  # Used to trigger dialing etc
  def trigger(control_id : Int32)
    logger.debug { "Sending trigger to Qsys: ct #{control_id}" }
    do_send("ct \"#{control_id}\"\n", wait: false)
  end

  # Compatibility Methods
  def fader(fader_ids : Ids, level : Int32)
    level = level / 10
    # TODO: fader_type: :fader
    ensure_array(fader_ids).each { |f_id| set_value(f_id, level, name: "fader#{f_id}") }
  end

  def faders(fader_ids : Ids, level : Int32)
    fader(fader_ids, level)
  end

  def mute(mute_ids : Ids, state : Bool = true)
    level = state ? 1 : 0
    # TODO: fader_type: :mute
    ensure_array(mute_ids).each { |m_id| set_value(m_id, level) }
  end

  def mutes(mute_ids : Array(Int32), state : Bool)
    mute(mute_ids, state)
  end

  def unmute(mute_ids : Array(Int32))
    mute(mute_ids, false)
  end

  def mute_toggle(mute_id : Int32)
    mute(mute_id, !self["fader#{mute_id}_mute"].try(&.as_bool))
  end

  def snapshot(name : String, index : Int32, ramp_time : Val = 1.5)
    do_send("ssl \"#{name}\" #{index} #{ramp_time}\n", wait: false)
  end

  def save_snapshot(name : String, index : Int32)
    do_send("sss \"#{name}\" #{index}\n", wait: false)
  end

  # For inter-module compatibility
  def query_fader(fader_ids : Ids)
    fad = ensure_array(fader_ids)[0]
    #TODO
    get_status(fad)#, fader_type: :fader)
  end

  def query_faders(fader_ids : Ids)
    # TODO: fader_type: :fader
    ensure_array(fader_ids).each { |f_id| get_status(f_id) }
  end

  def query_mute(fader_ids : Ids)
    fad = ensure_array(fader_ids)[0]
    # TODO: fader_type: :mute
    get_status(fad)
  end

  def query_mutes(fader_ids : Ids)
    # TODO: fader_type: :mute
    ensure_array(fader_ids).each { |fad| get_status(fad) }
  end

  def phone_number(number : String, control_id : Int32)
    set_string(control_id, number)
  end

  def phone_dial(control_id : Int32)
    trigger(control_id)
    schedule.in(200.milliseconds) { poll_change_group(:phone) }
  end

  def phone_hangup(control_id : Int32)
    phone_dial(control_id)
  end

  def phone_watch(control_ids : Ids)
    # Ensure change group exists
    group = create_change_group(:phone)
    group_id = group[:id]
    controls = group[:controls]

    # Add ids to change group
    ensure_array(control_ids).each do |id|
      unless controls.includes?(id)
        controls << id
        do_send("cga #{group_id} #{id}\n", wait: false)
      end
    end

    update_change_group(:phone, group_id, controls)
  end

  private def create_change_group(name) : Group
    if group = @change_groups[name]?
      return group
    end

    # Provide a unique group id
    next_id = @change_group_id
    @change_group_id += 1

    @change_groups[name] = {
      id: next_id,
      controls: Set(Int32).new
    }

    # create change group and poll every 2 seconds
    do_send("cgc #{next_id}\n", wait: false)
    do_send("cgsna #{next_id} 2000\n", wait: false)
    @change_groups[name]
  end

  private def update_change_group(name, id, controls) : Group
    @change_groups[name] = {
      id: id,
      controls: controls
    }
  end

  private def poll_change_group(name)
    if group = @change_groups[name]
      do_send("cgpna #{group[:id]}\n", wait: false)
    end
  end

  def received(data, task)
    process_response(data, task)
  end

  private def process_response(data, task, req = nil)
    logger.debug { "QSys sent: #{data}" }
    # rc == will disconnect

    resp = shellsplit(String.new(data))

    case resp[0]
    when "cv"
      control_id = resp[1]
      # string rep = resp[2]
      value = resp[3]
      position = resp[4].to_i

      self["pos_#{control_id}"] = position
    when "cvv" # Control status, Array of control status
    when "sr" # About response
    when "core_not_active", "bad_change_group_handle", "bad_command", "bad_id", "control_read_only", "too_many_change_groups"
    when "login_required"
    when "login_success"
    when "login_failed"
    when "rc"
    when "cmvv"
    else
    end

    task.try(&.success)
  end

  private def do_send(req, **options)
    send(req, **options) { |data, task| process_response(data, task, req) }
  end

  private def ensure_array(object)
    object.is_a?(Array) ? object : [object]
  end

  # Quick dirty port of https://github.com/ruby/ruby/blob/master/lib/shellwords.rb
  private def shellsplit(line : String) : Array(String)
    words = [] of String
    field = ""
    pattern = /\G\s*(?>([^\s\\\'\"]+)|'([^\']*)'|"((?:[^\"\\]|\\.)*)"|(\\.?)|(\S))(\s|\z)?/m
    line.scan(pattern) do |match|
      _, word, sq, dq, esc, garbage, sep = match.to_a
      raise ArgumentError.new("Unmatched quote: #{line.inspect}") if garbage
      field += (word || sq || dq.try(&.gsub(/\\([$`"\\\n])/, "\\1")) || esc.not_nil!.gsub(/\\(.)/, "\\1"))
      if sep
        words << field
        field = ""
      end
    end
    words
  end
end
