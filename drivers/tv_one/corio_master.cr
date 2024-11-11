require "placeos-driver"

# Documentation: https://aca.im/driver_docs/TV%20One/CORIOmaster-Commands-v1.7.0.pdf

class PlaceOS::Driver::Task
  # allows us to access request data in the response

  property request_payload : String? = nil
end

class TvOne::CorioMaster < PlaceOS::Driver
  # Discovery Information
  descriptive_name "tvOne CORIOmaster image processor"
  generic_name :VideoWall
  tcp_port 10001

  default_settings({
    username: "admin",
    password: "adminpw",
  })

  @username : String = "admin"
  @password : String = "adminpw"
  @ready : Bool = false
  @window_cache : Hash(UInt32, JSON::Any) = {} of UInt32 => JSON::Any

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
  end

  def disconnected
    schedule.clear
    self[:ready] = @ready = false
  end

  def connected
    # fallback if we don't get the ready signal
    schedule.in(30.seconds) { disconnect unless @ready }

    # maintain the connection
    schedule.every(1.minute) { do_poll }

    spawn { init_connection }
  end

  protected def init_connection
    task = exec("login", @username, @password, priority: 99, name: "login").get
    sync_state
  end

  def sync_state
    query("Preset.Take", expose_as: :preset)
    query_preset_list(expose_as: :presets)
    deep_query("Windows", expose_as: :windows)
    deep_query("Canvases", expose_as: :canvases)
    deep_query("Layouts", expose_as: :layouts)
    query "CORIOmax.Serial_Number", expose_as: :serial_number
    query "CORIOmax.Software_Version", expose_as: :firmware
  end

  def do_poll
    logger.debug { "polling device" }
    query "Preset.Take", expose_as: :preset
  end

  def preset(id : UInt32)
    set("Preset.Take", id).get
    self[:preset] = id
    if wins = @window_cache[id]?
      logger.debug { "loading cached window state" }
      self[:windows] = wins
    end

    # The full query of window params can take up to ~15 seconds. To
    # speed things up a little for other modules that depend on this
    # state, cache window info against preset ID's. These are then used
    # to provide instant status updates.
    #
    # As the device only supports a single connection the only time the
    # cache will contain stale data is following editing of presets, in
    # which case window state will update silently in the background.
    spawn do
      windows = query_windows
      logger.debug { "window cache for preset #{id} updated" }
      self[:windows] = @window_cache[id] = windows
    end
    id
  end

  def switch(map : Hash(String, Array(UInt32)))
    results = map.flat_map do |slot, windows|
      windows.map { |id| window(id, "Input", slot) }
    end

    spawn do
      # wait for operations to complete
      results.each(&.get)

      # patch state
      if state = status?(Hash(String, Hash(String, JSON::Any)), :windows)
        map.each do |slot, windows|
          value = JSON::Any.new(slot)
          windows.each do |id|
            if win = state["window#{id}"]?
              win["input"] = value
            end
          end
        end

        self["windows"] = state
      end
    end
    nil
  end

  def window(id : UInt32, property : String, value : Int64 | Bool | Nil | String)
    set("Window#{id}.#{property}", value)
  end

  def query_windows
    deep_query("Windows")
  end

  def preset_list
    query_preset_list
  end

  alias PresetList = Hash(Int32, NamedTuple(name: String, canvas: String, time: Int64))

  # Get the presets available for recall - for some inexplicible reason this
  # has a wildly different API to the rest of the system
  protected def query_preset_list(expose_as = nil)
    task = exec("Routing.Preset.PresetList").get(response_required: true)
    raise "exec failed" unless task.state.success?

    if preset_list = JSON.parse(task.payload).as_h?
      presets = preset_list.each_with_object(PresetList.new) do |(key, val), h|
        id = key[/\d+/].to_i
        name, canvas, time = val.as_s.split ","
        h[id] = {
          name:   name,
          canvas: canvas,
          time:   time.to_i64,
        }
      end

      self[expose_as] = presets unless expose_as.nil?
      presets
    end
  end

  protected def query(path, expose_as = nil, **opts)
    logger.debug { "querying: #{path}" }

    task = send("#{path}\r\n", **opts).get(response_required: true)
    raise "query failed" unless task.state.success?

    logger.debug { "query response: #{task.payload}" }

    result = JSON.parse(task.payload)
    self[expose_as] = result if expose_as
    result
  end

  protected def deep_query(path, expose_as = nil, **opts)
    logger.debug { "deep querying: #{path}" }

    result = query(path, **opts)
    logger.debug { "deep response: #{result.inspect}" }

    if val = result.as_h?
      val.each do |k, v|
        val[k] = deep_query(k) if v == "<...>"
      end
      val

      self[expose_as] = val if expose_as
      JSON::Any.new(val)
    else
      self[expose_as] = result if expose_as
      result
    end
  end

  protected def set(path, val, **opts)
    logger.debug { "setting #{path} to #{val}" }
    send("#{path} = #{val}\r\n", **opts, name: path)
  end

  protected def exec(command, *params, **opts)
    param_string = params.join ','
    logger.debug { "executing: #{command}(#{param_string})" }
    send "#{command}(#{param_string})\r\n", **opts
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received => #{data}" }

    # wait for an indicator string that hints at the start of the protocol
    if !@ready
      if data =~ /Interface Ready/i
        configure_tokenizer
        self[:ready] = @ready = true
      end
      return
    end

    # split the result into lines
    body = data.lines
    captures = /!(\w+)\W*(.*)$/.match(body.pop).try &.captures
    return task.try(&.abort("")) unless captures

    type = captures[0].as(String)
    message = captures[1].as(String).downcase

    # extract the path in the original request
    # can be "the.path" or "the.path = val" formats
    request = task.try &.request_payload.try(&.strip.downcase.split(" ")[0])

    # process the result
    case type
    when "Done"
      if request && request == message
        response = parse_response(body, request)
        task.try &.success(response)
      end
    when "Info"
      logger.info { "#{request} => #{message}" }
      task.try &.success
    when "Error"
      logger.error { message }
      task.try &.abort
    when "Event"
      logger.info { "unhandled event: #{message}" }
    else
      logger.error { "unhandled response: #{data}" }
      task.try &.abort
    end
  end

  protected def configure_tokenizer
    transport.tokenizer = Tokenizer.new do |io|
      buffer = String.new(io.peek)

      # start of final line of the payload
      final_start = buffer.index('!')
      next 0 unless final_start

      # end of the final line
      final_line_end = buffer.index("\r\n", final_start)

      if final_line_end
        final_line_end + 2
      else
        0
      end
    end
  end

  protected def parse_response(lines, command)
    kv_pairs = lines.map do |line|
      k, v = line.split("=")
      {k.strip.downcase, v.strip}
    end

    updates = kv_pairs.to_h.transform_values do |val|
      if resp = val.to_i64?
        resp
      else
        case val
        when "NULL"       then nil
        when /(Off)|(No)/ then false
        when /(On)|(Yes)/ then true
        else
          val
        end
      end
    end

    updates.reject! { |k, _| k.ends_with? "()" }

    return nil if updates.empty?

    if updates.size == 1 && (single_value = updates[command]?)
      # Single property query
      single_value
    elsif updates.values.all?(&.nil?)
      # Property list
      updates.keys
    else
      # Property set
      remove = "#{command}."
      updates.transform_keys { |x| x.sub(remove, "") }
    end
  end
end
