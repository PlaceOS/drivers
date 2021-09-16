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

  # Camera idx => Preset name => Preset id
  alias Presets = Hash(Int32, Hash(String, Int32))
  @presets : Presets = {} of Int32 => Hash(String, Int32)

  def on_load
    # NOTE:: on_load doesn't call on_update as on_update disconnects
    @peripheral_id = setting?(String, :peripheral_id)
    @presets = setting?(Presets, :camera_presets) || @presets
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
    driver = self
    driver.load_settings if driver.responds_to?(:load_settings)

    # Force a reconnect and event resubscribe following module updates.
    disconnect
  end

  def connected
    schedule.every(30.seconds) { heartbeat timeout: 35 }
    schedule.in(30.seconds) { disconnect unless @ready }
    @@status_mappings.each { |key, path| bind_status(path, key.to_s) }
  end

  def disconnected
    @ready = false
    transport.tokenizer = nil
    queue.clear abort_current: true

    clear_feedback_subscriptions
    schedule.clear
  end

  def generate_request_uuid
    UUID.random.to_s
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

    do_send request, multiline_body, name: name do |response|
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
      else
        error = response["CommandResponse/Status/status"]?
        if error
          reason = response["CommandResponse/Status/Reason"]?
          xpath = response["CommandResponse/Status/XPath"]?
          error_msg = "#{reason} (#{xpath})"
          promise.reject(RuntimeError.new error_msg)
          logger.error { error_msg }
        else
          error_msg = "bad response: #{response[:CommandResponse]}"
          logger.error { error_msg }
          promise.reject(RuntimeError.new error_msg)
        end
        :abort
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

    send "Echo off\n", priority: 96 do |data, task|
      response = String.new(data)
      task.success if response.includes? "\e[?1034h"
    end

    send "xPreferences OutputMode JSON\n", priority: 95, wait: false

    register_control_system

    push_config
    sync_config
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
    payload = String.new(data)
    logger.debug { "<- #{payload}" }

    if !@ready
      if payload =~ XAPI::LOGIN_COMPLETE
        @ready = true
        logger.info { "Connection ready, initializing connection" }
        init_connection
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
    logger.debug { "Subscribing to device feedback for #{path}" }

    unless feedback.contains? path
      request = XAPI.xfeedback :register, path
      # Always returns an empty response, nothing special to handle
      result = do_send request
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
    bind_feedback "/Status/#{path.tr " ", "/"}", status_key
    payload = xstatus(path)

    # single value?
    if payload.size == 1 && (value = payload[path]?)
      self[status_key] = value
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

    register_feedback path do |event|
      logger.debug { "Publishing #{path} event to #{mod_id}/#{channel}" }
      publish("#{mod_id}/#{channel}", event.to_json)
    end
  end

  # Clear external event subscribtions for a specific device path.
  def clear_event(path : String)
    logger.debug { "Clearing event subscription for #{path}" }
    unregister_feedback path
  end

  # ------------------------------
  # Connectivity management

  def register_control_system
    xcommand "Peripherals Connect",
      hash_args: Hash(String, JSON::Any::Type){"ID" => self.peripheral_id},
      name: "PlaceOS",
      type: :ControlSystem
  end

  def heartbeat(timeout : Int32)
    xcommand "Peripherals HeartBeat",
      hash_args: Hash(String, JSON::Any::Type){"ID" => self.peripheral_id},
      timeout: timeout
  end
end

require "./collaboration_endpoint/xapi"
