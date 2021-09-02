require "placeos-driver"
require "promise"
require "uuid"

class Cisco::CollaborationEndpoint < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Collaboration Endpoint"
  generic_name :CollaborationEndpoint
  tcp_port 22

  default_settings({
    ssh: {
      username: :cisco,
      password: :cisco,
    },
    building:    "building_code",
    ignore_macs: {
      "Cisco Phone Dock" => "7001b5",
    },
  })

  def on_load
    on_update
  end

  def on_unload; end

  def on_update
  end

  def connected
    # init_connection
    # register_control_system.then do
    #  schedule.every('30s') { heartbeat timeout: 35 }
    # end

    # push_config
    # sync_config
  end

  def disconnected
    # clear_device_subscriptions
    schedule.clear
  end

  def generate_request_uuid
    UUID.random.to_s
  end

  # ------------------------------
  # Exec methods

  # Push a configuration settings to the device.
  def xconfiguration(path : String, settings : String? = nil)
    if settings.nil?
      #    send_xconfigurations path
    else
      #    send_xconfigurations path, settings
    end
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
    hash_args : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type,
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

  protected def apply_configuration(path : String, setting : String, value : JSON::Any::Type)
    request = XAPI.xconfiguration(path, setting, value)
    promise = Promise.new(Bool)

    task = do_send request, name: "#{path} #{setting}" do |response|
      result = response["CommandResponse/Configuration/status"]?

      if result == "Error"
        reason = response["CommandResponse/Configuration/Reason"]?
        xpath = response["CommandResponse/Configuration/XPath"]?
        logger.error { "#{reason} (#{xpath})" }
        :abort
      else
        promise.resolve true
        true
      end
    end

    task.get
    promise.reject(RuntimeError.new "failed to set configuration: #{path} #{setting}: #{value}") if task.state == :abort
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
          logger.error { "#{reason} (#{xpath})" }
        else
          logger.error { "bad response: #{response[:CommandResponse]}" }
        end
        :abort
      end
    end

    task.get
    promise.reject(RuntimeError.new "failed to obtain status: #{path}") if task.state == :abort
    promise.get
  end

  protected def do_send(command, multiline_body = nil, **options)
    do_send(command, multiline_body, **options) { nil }
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
    response = XAPI.parse payload

    if task.nil?
      # device_subscriptions.notify(response)
      return
    end

    if task.xapi_request_id == response["ResultId"]?
      command_result = task.xapi_callback.try &.call(response)

      # device_subscriptions.notify(response) if command_result.nil?
      if command_result == :abort
        task.abort
      else
        task.success command_result
      end
    else
      # Otherwise support interleaved async events
      # device_subscriptions.notify(response)
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
end

require "./collaboration_endpoint/xapi"
