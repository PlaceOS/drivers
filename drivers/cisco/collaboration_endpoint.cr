require "placeos-driver"
require "promise"
require "uuid"

module Cisco::CollaborationEndpoint
  macro included
    @@status_mappings = {} of Symbol => String

    def self.map_status(**opts)
      @@status_mappings.merge! opts.to_h
    end
  end

  # used by many of the commands
  enum Toogle
    On
    Off
  end

  getter peripheral_id : String do
    uuid = generate_request_uuid
    @ignore_update = true
    define_setting(:peripheral_id, uuid)
    uuid
  end

  protected getter feedback : Feedback = Feedback.new
  @ready : Bool = false
  @init_called : Bool = false

  # Camera idx => Preset name => Preset id
  alias Presets = Hash(Int32, Hash(String, Int32))
  @presets : Presets = {} of Int32 => Hash(String, Int32)
  getter feedback_paths : Array(String) = [] of String

  def on_load
    # NOTE:: on_load doesn't call on_update as on_update disconnects
    queue.delay = 50.milliseconds
    queue.timeout = 2.seconds
    @peripheral_id = setting?(String, :peripheral_id)
    @presets = setting?(Presets, :camera_presets) || @presets
    self[:camera_presets] = @presets.transform_values { |val| val.keys }
    driver = self
    driver.load_settings if driver.responds_to?(:load_settings)
  end

  # used when saving settings from the driver
  # this prevents needless disconnects
  @ignore_update : Bool = false

  def on_update
    if @ignore_update
      @ignore_update = false
      return
    end
    @presets = setting?(Presets, :camera_presets) || @presets
    self[:camera_presets] = @presets.transform_values { |val| val.keys }
    driver = self
    driver.load_settings if driver.responds_to?(:load_settings)

    # Force a reconnect and event resubscribe following module updates.
    disconnect
  end

  @last_received : Int64 = 0_i64

  def connected
    schedule.every(2.minutes) { ensure_feedback_registered }
    schedule.every(30.seconds) do
      if @last_received > 40.seconds.ago.to_unix
        heartbeat timeout: 35
      else
        disconnect
      end
    end
    schedule.in(10.seconds) do
      init_connection unless @ready || @init_called
      schedule.in(15.seconds) { disconnect if !@ready || self["configuration"]?.nil? }
    end
  end

  def disconnected
    self[:ready] = @ready = false
    @init_called = false
    @feedback_paths = [] of String
    transport.tokenizer = nil
    queue.clear abort_current: true

    clear_feedback_subscriptions
    schedule.clear
  end

  def generate_request_uuid
    UUID.random.to_s
  end

  def ensure_feedback_registered
    send "xPreferences OutputMode JSON\n", priority: 0, wait: false, name: "output_json"
    results = @feedback_paths.map do |path|
      request = XAPI.xfeedback :register, path
      # Always returns an empty response, nothing special to handle
      do_send(request, priority: 0, name: path)
    end
    spawn(same_thread: true) do
      success = 0
      results.each do |task|
        begin
          success += 1 if task.get.state.success?
        rescue
        end
      end
      logger.debug { "FEEDBACK REGISTERED #{success}" }
      disconnect unless success > 0
    end
    @feedback_paths.size
  end

  # ------------------------------
  # Exec methods

  alias JSONBasic = Enumerable::JSONBasic
  alias Config = Hash(String, Hash(String, JSONBasic))

  # Push a configuration settings to the device.
  def xconfigurations(config : Config)
    config.each { |path, settings| xconfiguration(path, settings) }
  end

  # Execute an xCommand on the device.
  def xcommand(
    command : String,
    multiline_body : String? = nil,
    hash_args : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type,
    **kwargs
  )
    request = XAPI.xcommand(command, **kwargs.merge({hash_args: hash_args}))
    name = if kwargs.empty?
             command
           elsif kwargs.size == 1
             "#{command} #{kwargs.keys.to_a.first}"
           end

    # use default queue priority is not specified
    priority = kwargs[:priority]? || queue.priority

    do_send request, multiline_body, name: name, priority: priority do |response|
      # The result keys are a little odd: they're a concatenation of the
      # last two command elements and 'Result', unless the command
      # failed in which case it's just 'Result'.
      # For example:
      #   xCommand Video Input SetMainVideoSource ...
      # becomes:
      #   InputSetMainVideoSourceResult
      result_key = command.split(' ').last(2).join("") + "Result"
      command_result = response["CommandResponse/#{result_key}/status"]?
      failure_result = response["CommandResponse/Result/Reason"]?

      result = command_result || failure_result

      if result
        if result == "OK"
          result
        else
          failure_result ||= response["CommandResponse/#{result_key}/Reason"]?
          logger.error { failure_result.inspect }
          :abort
        end
      else
        logger.warn { "Unexpected response format" }
        :abort
      end
    end
  end

  # Apply a single configuration on the device.
  def xconfiguration(
    path : String,
    hash_args : Hash(String, JSONBasic) = {} of String => JSONBasic,
    **kwargs
  )
    promises = hash_args.map do |setting, value|
      apply_configuration(path, setting, value)
    end
    kwargs.each do |setting, value|
      promise = apply_configuration(path, setting, value)
      promises << promise
    end
    Promise.all(promises).get.first
  end

  protected def apply_configuration(path : String, setting : String, value : JSONBasic)
    request = XAPI.xconfiguration(path, setting, value)
    promise = Promise.new(Bool)

    task = do_send request, name: "#{path} #{setting}" do |response|
      result = response["CommandResponse/Configuration/status"]?

      if result == "Error"
        reason = response["CommandResponse/Configuration/Reason"]?
        xpath = response["CommandResponse/Configuration/XPath"]?

        error_msg = "#{reason} (#{xpath})"
        promise.reject(RuntimeError.new error_msg)
        logger.error { error_msg }
        :abort
      else
        promise.resolve true
        true
      end
    end

    spawn(same_thread: true) do
      task.get
      promise.reject(RuntimeError.new "failed to set configuration: #{path} #{setting}: #{value}") if task.state == :abort
    end
    promise
  end

  def xstatus(path : String)
    request = XAPI.xstatus path
    promise = Promise.new(Hash(String, Enumerable::JSONComplex))

    task = do_send request do |response|
      prefix = "Status/#{XAPI.tokenize(path).join('/')}"
      results = {} of String => Enumerable::JSONComplex
      response.each do |key, value|
        results[key] = value if key.starts_with?(prefix)
      end

      if !results.empty?
        promise.resolve results
        results
      elsif error = response["Status/status"]? || response["CommandResponse/Status/status"]?
        reason = response["Status/Reason"]? || response["CommandResponse/Status/Reason"]?
        xpath = response["Status/XPath"]? || response["CommandResponse/Status/XPath"]?
        error_msg = "#{reason} (#{xpath})"
        promise.reject(RuntimeError.new error_msg)
        logger.error { error_msg }
        :abort
      else
        results[prefix] = nil
        promise.resolve results
        results
      end
    end

    spawn(same_thread: true) do
      task.get
      promise.reject(RuntimeError.new "failed to obtain status: #{path}") if task.state == :abort
    end
    promise.get
  end

  # ------------------------------
  # Base comms

  protected def init_connection
    @init_called = true

    transport.tokenizer = Tokenizer.new do |io|
      raw = io.gets_to_end
      data = raw.lstrip
      index = if data.starts_with?("{")
                count = 0
                pos = 0
                data.each_char_with_index do |char, i|
                  pos = i
                  count += 1 if char == '{'
                  count -= 1 if char == '}'
                  break if count.zero?
                end
                pos if count.zero?
              else
                data =~ XAPI::COMMAND_RESPONSE
              end

      if index
        message = data[0..index]
        index += raw.byte_index_to_char_index(raw.byte_index(message).not_nil!).not_nil!
        index = raw.char_index_to_byte_index(index + 1)
      end

      index || -1
    end

    send "xPreferences OutputMode JSON\n", priority: 95, wait: false, name: "output_json"
    register_control_system.get
    self[:ready] = @ready = true

    push_config
    sync_config
  rescue error
    logger.warn(exception: error) { "error configuring xapi transport" }
  ensure
    @@status_mappings.each do |key, path|
      begin
        bind_status(path, key.to_s)
      rescue error
        logger.warn(exception: error) { "failed to bind status #{path} (#{key})" }
      end
    end

    driver = self
    driver.connection_ready if driver.responds_to?(:connection_ready)
  end

  protected def do_send(command, multiline_body = nil, **options)
    do_send(command, multiline_body, **options) { true }
  end

  protected def do_send(command, multiline_body = nil, **options, &callback : ::PlaceOS::Driver::Task::ResponseCallback)
    request_id = generate_request_uuid
    request = "#{command} | resultId=\"#{request_id}\"\n"

    logger.debug { "-> #{request}" }
    request = "#{request}#{multiline_body}\n.\n" if multiline_body

    task = send request, **options
    task.xapi_request_id = request_id
    task.xapi_callback = callback
    task
  end

  def received(data, task)
    @last_received = Time.utc.to_unix
    payload = String.new(data)
    logger.debug { "<- #{payload}" }

    if !@ready
      if payload =~ XAPI::LOGIN_COMPLETE
        send "xPreferences OutputMode JSON\n", priority: 95, wait: false, name: "output_json"
        self[:ready] = @ready = true
        logger.info { "Connection ready, initializing connection" }
        spawn(same_thread: true) do
          sleep 0.5
          init_connection unless @init_called
        end
      end
      return
    end

    response = XAPI.parse payload

    return feedback.notify(response) if task.nil?

    if task.xapi_request_id == response["ResultId"]?
      command_result = task.xapi_callback.try &.call(response)

      feedback.notify(response) if command_result.nil?
      command_result == :abort ? task.abort : task.success(command_result)
    else
      feedback.notify(response)
    end
  rescue error : JSON::ParseException
    payload = String.new(data).strip
    case payload
    when "OK"
      task.try &.success payload
    when "Command not recognized."
      logger.error { "Command not recognized: `#{task.try &.request_payload}`" }
      task.try &.abort payload
    else
      logger.debug { "Malformed device response: #{error}\n#{payload}" }
      task.try &.abort "Malformed device response: #{error}"
    end
  end

  # ------------------------------
  # Event subscription

  # Subscribe to feedback from the device.
  def register_feedback(path : String, &update_handler : Proc(String, Enumerable::JSONComplex, Nil))
    if !@ready
      unless feedback.contains? path
        @feedback_paths << path
        @feedback_paths.uniq!
        feedback.insert(path, &update_handler)
      end
      return true
    end

    logger.debug { "Subscribing to device feedback for #{path}" }

    unless feedback.contains? path
      @feedback_paths << path
      @feedback_paths.uniq!
      request = XAPI.xfeedback :register, path
      # Always returns an empty response, nothing special to handle
      result = do_send request, name: path
    end

    feedback.insert path, &update_handler

    result.try(&.get) || true
  end

  def unregister_feedback(path : String)
    return clear_feedback_subscriptions if path == "/"
    logger.debug { "Unsubscribing feedback for #{path}" }
    feedback.remove path
    do_send XAPI.xfeedback(:deregister, path)
  end

  def clear_feedback_subscriptions
    logger.debug { "Unsubscribing all feedback" }
    @status_keys.clear
    feedback.clear
    do_send XAPI.xfeedback(:deregister_all)
  end

  # ------------------------------
  # Module status

  @status_keys = Hash(String, Hash(String, Enumerable::JSONComplex)).new do |hash, key|
    hash[key] = {} of String => Enumerable::JSONComplex
  end

  # Bind arbitary device feedback to a status variable.
  def bind_feedback(path : String, status_key : String)
    register_feedback path do |value_path, value|
      if value_path == path
        self[status_key] = value
      else
        key_path = value_path.sub(path, "")
        hash = @status_keys[status_key]
        hash[key_path] = value
        self[status_key] = hash
      end
    end
  end

  # Bind device status to a module status variable.
  def bind_status(path : String, status_key : String)
    bind_path = "Status/#{path.tr " ", "/"}"
    bind_feedback "/#{bind_path}", status_key
    payload = xstatus(path)

    # single value?
    if payload.size == 1 && payload.has_key?(bind_path)
      self[status_key] = payload[bind_path]
    else
      self[status_key] = @status_keys[status_key] = payload.transform_keys do |key|
        key.sub(path, "")
      end
    end
    payload
  end

  def push_config
    if config = setting?(Config, :configuration)
      xconfigurations config
    end
  end

  def sync_config
    bind_feedback "/Configuration", "configuration"
    send "xConfiguration *\n", wait: false
  end

  # ------------------------------
  # External feedback subscriptions

  # Subscribe another module to async device events.
  # Callback methods must be of arity 1 and public.
  def on_event(path : String, mod_id : String, channel : String)
    logger.debug { "Registering callback for #{path} to #{mod_id}/#{channel}" }
    register_feedback path do |event_path, value|
      event_json = {event_path => value}.to_json
      logger.debug { "Publishing #{path} event to #{mod_id}/#{channel} with payload #{event_json}" }
      publish("#{mod_id}/#{channel}", event_json)
    end
  end

  # Clear external event subscribtions for a specific device path.
  def clear_event(path : String)
    logger.debug { "Clearing event subscription for #{path}" }
    unregister_feedback path
  end

  # ------------------------------
  # Connectivity management

  protected def register_control_system
    xcommand "Peripherals Connect",
      hash_args: Hash(String, JSON::Any::Type){"ID" => self.peripheral_id},
      name: "PlaceOS",
      type: :ControlSystem
  end

  protected def heartbeat(timeout : Int32)
    # high priority as otherwise the VC will indicate we've disconnected
    xcommand "Peripherals HeartBeat",
      hash_args: Hash(String, JSON::Any::Type){"ID" => self.peripheral_id},
      timeout: timeout,
      priority: 99
  end
end

require "./collaboration_endpoint/xapi"
