require "placeos-driver"
require "./remote_debug_models"

# Remote debugging of PlaceOS apps, such as Booking Panel, Control and Signage.
# The apps find this driver from the `remote_debug` binding of the
# organisation zone. A device reads its `device:<id>` binding, sends logs with
# `post_logs` and sends command results with `command_result`.
#
# Interface: https://github.com/PlaceOS/user-interfaces/blob/develop/docs/remote-debug.md
# Device side: https://github.com/PlaceOS/user-interfaces/blob/develop/libs/common/src/lib/remote-debug.ts
class Place::RemoteDebug < PlaceOS::Driver
  descriptive_name "PlaceOS Remote Debug"
  generic_name :RemoteDebug
  description <<-DESC
    Get the logs, status and screen captures of PlaceOS apps by their device ID.

    To turn it on, set the `remote_debug` binding of the organisation zone to
    `{"id": "<id of this system>", "module": "RemoteDebug"}`.

    Add a StaffAPI module to this system so the driver can remove old screen
    captures from the uploads. Only support users can request logs and send commands.
    DESC

  # Most entries that the driver keeps for each device
  MAX_DEVICE_ENTRIES = 5000
  # Most command results that the driver keeps for each device
  MAX_DEVICE_RESULTS = 50
  # Most snapshots and animations that the driver keeps for each device
  MAX_DEVICE_MEDIA = 3
  # Most devices that the driver keeps data for, and most devices with a request or commands
  MAX_DEVICES = 1000
  # Most commands for each device. The device reads the first 20
  MAX_COMMANDS = 20
  # Most keys in a `settings` command
  MAX_SETTINGS_KEYS = 50
  # Most entries in one `post_logs` call. The device sends 100 maximum
  MAX_BATCH = 100
  # Most characters in the JSON of a command result. The device sends 100,000 maximum
  MAX_RESULT_LENGTH = 100_000
  # Most buffered entries that one request gets
  MAX_HISTORY         = 1000
  DEFAULT_DURATION_MS = 15 * 60 * 1000
  MAX_DURATION_MS     = 60 * 60 * 1000
  # Time before the driver removes a command that the device did not run
  COMMAND_TIMEOUT = 15.minutes
  # Most time between updates of `devices` when only `last_seen` changes
  SEEN_INTERVAL_MS = 60 * 1000
  DEVICE_ID        = /\A[A-Za-z0-9_-]{1,64}\z/

  # State of each device with a log request or commands
  @states = {} of String => RemoteDebugDeviceState
  # Devices that called the driver, by ID
  @devices = {} of String => RemoteDebugDevice
  @devices_published_at = 0_i64
  @logs = {} of String => RemoteLogsView
  @results = {} of String => Array(RemoteDebugCommandResult)
  @media = {} of String => Array(RemoteDebugMedia)
  # End timers of the active log requests, by device ID
  @expiry = {} of String => PlaceOS::Driver::Proxy::Scheduler::TaskWrapper

  def on_load
    self[:devices] = @devices
  end

  # ===================================
  # Methods for the people who debug
  # ===================================

  # Sets a new log request for a device. Returns the request ID
  @[Security(Level::Support)]
  def request_logs(device_id : String, level : RemoteLogLevel, options : RemoteLogRequestOptions? = nil) : String
    check_device_id device_id
    options ||= RemoteLogRequestOptions.new
    request = RemoteLogRequest.new(
      id: new_id,
      level: level,
      history: options.history.try(&.clamp(0, MAX_HISTORY)),
      before: options.before,
      duration: options.duration.try(&.clamp(0, MAX_DURATION_MS)),
    )
    state_for(device_id).logs = request
    publish_state device_id
    start_expiry device_id, request.duration
    request.id
  end

  # Changes the level of the active log request. The request keeps its ID
  @[Security(Level::Support)]
  def set_level(device_id : String, level : RemoteLogLevel) : Nil
    state = @states[device_id]?
    logs = state.try &.logs
    # The device ignores the same level, so its duration does not start again
    return if state.nil? || logs.nil? || logs.level == level
    state.logs = RemoteLogRequest.new(logs.id, level, logs.history, logs.before, logs.duration)
    publish_state device_id
    # The device starts the duration again when the level changes
    start_expiry device_id, logs.duration
  end

  # Ends the active log request of a device
  @[Security(Level::Support)]
  def stop_logs(device_id : String) : Nil
    @expiry.delete(device_id).try &.cancel
    state = @states[device_id]?
    return unless state && state.logs
    state.logs = nil
    publish_state device_id
  end

  # Adds a command for a device. Returns the command ID.
  # `options` holds the fields of the command, such as `keys`, `path` or `width`
  @[Security(Level::Support)]
  def send_command(device_id : String, type : RemoteDebugCommandType, options : RemoteDebugCommandOptions? = nil) : String
    check_device_id device_id
    command = build_command(type, options || RemoteDebugCommandOptions.new)
    count = @states[device_id]?.try(&.commands.size) || 0
    raise ArgumentError.new("device #{device_id} has #{MAX_COMMANDS} commands already") if count >= MAX_COMMANDS
    state_for(device_id).commands << command
    publish_state device_id
    schedule.in(COMMAND_TIMEOUT) { remove_command(device_id, command.id) }
    command.id
  end

  # ===================================
  # Methods that the devices call
  # ===================================

  # Adds the entries of a device. Ignores calls for a request that is not active
  def post_logs(device_id : String, request_id : String, entries : Array(RemoteLogEntry), device : RemoteDebugDevice) : Nil
    logs = @states[device_id]?.try &.logs
    return unless logs && logs.id == request_id && device.id == device_id
    seen device_id, device

    view = @logs[device_id]?
    # A new `started_at` shows that the app reloaded and `seq` started again
    same_session = view && view.device.started_at == device.started_at
    old = view && same_session ? view.entries : [] of RemoteLogEntry
    known = old.map(&.seq).to_set
    # The device sends a failed batch again, so skip the entries that we have
    added = entries.first(MAX_BATCH).reject { |entry| known.includes?(entry.seq) }.uniq!(&.seq)
    return if same_session && added.empty?

    merged = (old + added).sort_by!(&.seq).last(MAX_DEVICE_ENTRIES)
    self["logs:#{device_id}"] = @logs[device_id] = RemoteLogsView.new(device, merged)
  end

  # Keeps the result of a command and removes the command
  def command_result(device_id : String, command_id : String, result : RemoteDebugResult, device : RemoteDebugDevice) : Nil
    command = @states[device_id]?.try &.commands.find(&.id.==(command_id))
    return unless command && device.id == device_id
    seen device_id, device
    remove_command device_id, command_id

    if result.to_json.size > MAX_RESULT_LENGTH
      result = RemoteDebugResult.new(ok: false, error: "Result is too large")
    end
    add_media(device_id, command_id, result) if command.type.media?

    results = @results[device_id]? || [] of RemoteDebugCommandResult
    results << RemoteDebugCommandResult.new(command.id, command.type, result, now_ms)
    self["results:#{device_id}"] = @results[device_id] = results.last(MAX_DEVICE_RESULTS)
  end

  # ===================================
  # Helpers
  # ===================================

  protected def check_device_id(device_id : String) : Nil
    raise ArgumentError.new("invalid device ID: #{device_id}") unless DEVICE_ID.matches?(device_id)
  end

  protected def new_id : String
    Random::Secure.hex(6)
  end

  protected def now_ms : Int64
    Time.utc.to_unix_ms
  end

  # The state of a device. Adds an empty state when there is none
  protected def state_for(device_id : String) : RemoteDebugDeviceState
    @states[device_id]? || begin
      raise ArgumentError.new("#{MAX_DEVICES} devices have a request or commands already") if @states.size >= MAX_DEVICES
      @states[device_id] = RemoteDebugDeviceState.new
    end
  end

  # Writes the `device:<id>` binding. An empty state is removed and shows as `null`
  protected def publish_state(device_id : String) : Nil
    state = @states[device_id]?
    if state && state.empty?
      @states.delete(device_id)
      state = nil
    end
    self["device:#{device_id}"] = state
  end

  # Ends the log request of a device when its duration ends
  protected def start_expiry(device_id : String, duration : Int32?) : Nil
    @expiry.delete(device_id).try &.cancel
    duration = (duration || DEFAULT_DURATION_MS).clamp(0, MAX_DURATION_MS)
    @expiry[device_id] = schedule.in(duration.milliseconds) do
      @expiry.delete(device_id)
      stop_logs device_id
    end
  end

  protected def build_command(type : RemoteDebugCommandType, options : RemoteDebugCommandOptions) : RemoteDebugCommand
    id = new_id
    case type
    in .settings?
      keys = options.keys
      raise ArgumentError.new("settings needs keys") unless keys
      raise ArgumentError.new("settings has #{MAX_SETTINGS_KEYS} keys maximum") if keys.size > MAX_SETTINGS_KEYS
      RemoteDebugCommand.new(id, type, keys: keys)
    in .navigate?
      path = options.path
      raise ArgumentError.new("navigate needs a path that starts with /") unless path && path.starts_with?('/')
      RemoteDebugCommand.new(id, type, path: path)
    in .snapshot?
      RemoteDebugCommand.new(id, type, width: options.width)
    in .animation?
      RemoteDebugCommand.new(id, type, width: options.width, duration: options.duration, fps: options.fps, format: options.format)
    in .status?, .storage?, .reload?, .clear_cache?
      RemoteDebugCommand.new(id, type)
    end
  end

  protected def remove_command(device_id : String, command_id : String) : Nil
    commands = @states[device_id]?.try &.commands
    return unless commands
    count = commands.size
    commands.reject!(&.id.==(command_id))
    publish_state(device_id) if commands.size != count
  end

  # Keeps the upload of a `snapshot` or `animation` result in `media:<id>`.
  # Removes the uploads that the driver no longer keeps
  protected def add_media(device_id : String, command_id : String, result : RemoteDebugResult) : Nil
    data = result.data
    return unless result.ok && data
    media = begin
      RemoteDebugMedia.from_json(data.to_json)
    rescue error : JSON::Error
      logger.warn { "invalid media from #{device_id}: #{error.message}" }
      return
    end
    media.id = command_id
    media.url = "/api/engine/v2/uploads/#{URI.encode_path_segment(media.upload_id)}/url"
    media.received_at = now_ms

    list = @media[device_id]? || [] of RemoteDebugMedia
    list << media
    list.shift(list.size - MAX_DEVICE_MEDIA).each { |old| remove_upload old.upload_id } if list.size > MAX_DEVICE_MEDIA
    self["media:#{device_id}"] = @media[device_id] = list
  end

  # Removes an upload with the StaffAPI module of this system, if there is one
  protected def remove_upload(upload_id : String) : Nil
    return unless system.exists?(:StaffAPI)
    system[:StaffAPI].upload_remove(upload_id)
  rescue error
    logger.warn(exception: error) { "failed to remove upload #{upload_id}" }
  end

  # Adds or updates a device in `devices`. Keeps the `MAX_DEVICES` devices
  # that were seen last, and removes the data of the other devices.
  # Writes `devices` when a device changes, or once each minute when only `last_seen` changes
  protected def seen(device_id : String, device : RemoteDebugDevice) : Nil
    now = now_ms
    previous = @devices[device_id]?
    # Compare all the fields but `last_seen`
    device.last_seen = previous.try &.last_seen
    changed = previous != device
    device.last_seen = now
    @devices[device_id] = device

    if @devices.size > MAX_DEVICES
      oldest = @devices.min_by { |_id, item| item.last_seen || 0_i64 }[0]
      forget oldest
      changed = true
    end

    return unless changed || now - @devices_published_at >= SEEN_INTERVAL_MS
    @devices_published_at = now
    self[:devices] = @devices
  end

  # Removes the logs, results and uploads of a device
  protected def forget(device_id : String) : Nil
    @devices.delete(device_id)
    @logs.delete(device_id)
    @results.delete(device_id)
    @media.delete(device_id).try &.each { |media| remove_upload media.upload_id }
    self["logs:#{device_id}"] = nil
    self["results:#{device_id}"] = nil
    self["media:#{device_id}"] = nil
  end
end
