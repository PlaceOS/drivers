require "placeos-driver"

# Documentation https://q-syshelp.qsc.com/Content/External_Control_APIs/ECP/ECP_Commands.htm

class Qsc::QSysControl < PlaceOS::Driver
  # Discovery Information
  tcp_port 1702
  descriptive_name "QSC Audio DSP External Control"
  generic_name :Mixer

  default_settings({
    _change_groups: {
      "room123_phone" => {
        id:       1,
        controls: ["VoIPCallStatusProgress", "VoIPCallStatusRinging", "VoIPCallStatusOffHook"],
      },
    },
  })

  alias Group = NamedTuple(id: Int32, controls: Set(String))
  alias Ids = String | Array(String)
  alias Val = Int32 | Float64

  @username : String? = nil
  @password : String? = nil

  @connected : Bool = false
  @change_group_id : Int32 = 30
  @em_id : String? = nil
  @emergency_subscribe : PlaceOS::Driver::Subscriptions::Subscription? = nil
  @history = {} of String => Symbol

  @static_change_groups = {} of String => Group
  @dynamic_change_groups = {} of String => Group

  def on_load
    transport.tokenizer = Tokenizer.new("\r\n")
    queue.retries = 1
    on_update
  end

  def on_update
    @username = setting?(String, :username)
    @password = setting?(String, :password)

    @static_change_groups = setting?(Hash(String, Group), :change_groups) || {} of String => Group

    login if @username && @connected
    recreate_change_groups
  end

  def connected
    @connected = true
    login if @username
    recreate_change_groups
    schedule.every(40.seconds) do
      logger.debug { "Maintaining Connection" }
      about
    end
  end

  def disconnected
    @connected = false
    schedule.clear
  end

  protected def recreate_change_groups
    return unless @connected
    change_groups = @static_change_groups.merge @dynamic_change_groups
    change_groups.each do |_, group|
      logger.debug { "change groups" }
      group_id = group[:id]
      controls = group[:controls]

      # Re-create change groups and poll every 2 seconds
      do_send("cgc #{group_id}\n")        # , wait: false)
      do_send("cgsna #{group_id} 2000\n") # , wait: false)
      controls.each do |id|
        do_send("cga #{group_id} #{id}\n") # , wait: false)
      end
    end

    em_id = setting?(String, :emergency)

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
        do_send("cga #{group_id} #{em_id}\n") # , wait: false)
      end
    end
  end

  def get_status(control_id : String, **options)
    fader_type = options[:fader_type]?
    @history[control_id] = fader_type if fader_type
    do_send("cg #{control_id}\n", **options)
  end

  def set_position(control_id : String, position : Int32, ramp_time : Val? = nil)
    if ramp_time
      do_send("cspr \"#{control_id}\" #{position} #{ramp_time}\n") # , wait: false)
      schedule.in(ramp_time.seconds + 200.milliseconds) { get_status(control_id) }
    else
      do_send("csp \"#{control_id}\" #{position}\n")
    end
  end

  def set_value(control_id : String, value : Val, ramp_time : Val? = nil, **options)
    fader_type = options[:fader_type]?
    @history[control_id] = fader_type if fader_type
    if ramp_time
      do_send("csvr \"#{control_id}\" #{value} #{ramp_time}\n", **options) # , wait: false)
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
  def trigger(control_id : String)
    logger.debug { "Sending trigger to Qsys: ct #{control_id}" }
    do_send("ct \"#{control_id}\"\n") # , wait: false)
  end

  # Compatibility Methods
  def fader(fader_ids : Ids, level : Val)
    level = level.to_f.clamp(0.0, 100.0)
    percentage = level / 100.0
    range = -100..20

    # adjust into range
    level_actual = percentage * (range.size - 1).to_f
    level_actual = (level_actual + range.begin.to_f).round(1)

    ensure_array(fader_ids).each { |f_id| set_value(f_id, level_actual, name: "fader#{f_id}", fader_type: :fader) }
  end

  def faders(fader_ids : Ids, level : Val)
    fader(fader_ids, level)
  end

  def mute(mute_ids : Ids, state : Bool = true)
    level = state ? 1 : 0
    ensure_array(mute_ids).each { |m_id| set_value(m_id, level, fader_type: :mute) }
  end

  def mutes(mute_ids : Ids, state : Bool)
    mute(mute_ids, state)
  end

  def unmute(mute_ids : Ids)
    mute(mute_ids, false)
  end

  def mute_toggle(mute_id : Ids)
    mute(mute_id, !self["fader#{mute_id}_mute"]?.try(&.as_bool))
  end

  def snapshot(name : String, index : Int32, ramp_time : Val = 1.5)
    do_send("ssl \"#{name}\" #{index} #{ramp_time}\n") # , wait: false)
  end

  def save_snapshot(name : String, index : Int32)
    do_send("sss \"#{name}\" #{index}\n") # , wait: false)
  end

  # For inter-module compatibility
  def query_fader(fader_ids : Ids)
    fad = ensure_array(fader_ids)[0]
    get_status(fad, fader_type: :fader)
  end

  def query_faders(fader_ids : Ids)
    ensure_array(fader_ids).each { |f_id| get_status(f_id, fader_type: :fader) }
  end

  def query_mute(fader_ids : Ids)
    fad = ensure_array(fader_ids)[0]
    get_status(fad, fader_type: :mute)
  end

  def query_mutes(fader_ids : Ids)
    ensure_array(fader_ids).each { |fad| get_status(fad, fader_type: :mute) }
  end

  def phone_number(number : String, control_id : String)
    set_string(control_id, number)
  end

  def phone_dial(control_id : String)
    trigger(control_id)
    schedule.in(200.milliseconds) { poll_change_group(:phone) }
  end

  def phone_hangup(control_id : String)
    phone_dial(control_id)
  end

  private def create_change_group(name) : Group
    name = name.to_s

    if group = @dynamic_change_groups[name]?
      return group
    end

    # Provide a unique group id
    next_id = @change_group_id
    @change_group_id += 1

    @dynamic_change_groups[name] = {
      id:       next_id,
      controls: Set(String).new,
    }

    # create change group and poll every 2 seconds
    do_send("cgc #{next_id}\n")        # , wait: false)
    do_send("cgsna #{next_id} 2000\n") # , wait: false)
    @dynamic_change_groups[name]
  end

  private def update_change_group(name, id, controls) : Group
    @dynamic_change_groups[name.to_s] = {
      id:       id,
      controls: controls,
    }
  end

  private def poll_change_group(name)
    if group = @dynamic_change_groups[name]
      do_send("cgpna #{group[:id]}\n") # , wait: false)
    end
  end

  def received(data, task)
    data = String.new(data)
    puts "GOT: #{data}"
    return task.try(&.success) if data == "none\r\n"
    logger.debug { "QSys sent: #{data}" }
    resp = shellsplit(data)

    case resp[0]
    when "cv"
      control_id = resp[1]
      # string rep = resp[2]
      value = resp[-2]
      position = resp[-1].to_f

      self["pos_#{control_id}"] = position

      puts "PROCESSING #{control_id} = #{position}"

      if type = @history[control_id]?
        puts "WE HAVE A TYPE! #{type}"

        case type
        when :fader
          range = -100..20
          vol_percent = ((value.to_f - range.begin.to_f) / (range.size - 1).to_f) * 100.0
          self["fader#{control_id}"] = vol_percent.round(2)
        when :mute
          self["fader#{control_id}_mute"] = value.to_i == 1
        end
      else
        value = resp[2]
        if value == "false" || value == "true"
          self[control_id] = value == "true"
        else
          self[control_id] = value.gsub('_', ' ')
        end
        logger.debug { "Received response from unknown ID type: #{control_id} == #{value}" }
      end
    when "cvv" # Control status, Array of control status
      control_id = resp[1]
      count = resp[2].to_i

      if type = @history[control_id]?
        # Skip strings and extract the values
        next_count = count + 3
        count = resp[next_count].to_i
        1.upto(count) do |index|
          value = resp[next_count + index]

          case type
          when :fader
            range = -100..20
            vol_percent = ((value.to_f - range.begin.to_f) / (range.size - 1).to_f) * 100.0
            self["fader#{control_id}"] = vol_percent.round(2)
          when :mute
            self["fader#{control_id}_mute"] = value == 1
          end
        end
      else
        # Don't skip strings here
        next_count = 2
        1.upto(count) do |index|
          value = resp[next_count + index]

          if value == "false" || value == "true"
            self[control_id] = value == "true"
          else
            self[control_id] = value.gsub('_', ' ')
          end
        end
        logger.debug { "Received response from unknown ID type: #{control_id}" }

        # Jump to the position values
        next_count = count + 3
        count = resp[next_count].to_i
      end

      # Grab the positions
      next_count = next_count + count + 1
      count = resp[next_count].to_i
      1.upto(count) do |index|
        value = resp[next_count + index]
        self["pos_#{control_id}"] = value
      end
    when "sr" # About response
      self[:design_name] = resp[1]
      self[:is_primary] = resp[3] == "1"
      self[:is_active] = resp[4] == "1"
    when "core_not_active", "bad_change_group_handle", "bad_command", "bad_id", "control_read_only", "too_many_change_groups"
      return task.try(&.abort("Error response received: #{data}"))
    when "login_required"
      login if @username
      return task.try(&.abort("Login is required!"))
    when "login_success"
      logger.debug { "Login success!" }
    when "login_failed"
      return task.try(&.abort("Invalid login details provided"))
    when "rc"
      logger.warn { "System is notifying us of a disconnect!" }
    when "cmvv"
      logger.debug { "received cmvv response" }
    else
      logger.warn { "Unknown response received #{data}" }
    end

    task.try(&.success)
  end

  private def do_send(req, fader_type : Symbol? = nil, **options)
    logger.debug { "sending #{req}" }
    send(req, **options)
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
