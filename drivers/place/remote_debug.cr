require "placeos-driver"
require "./remote_debug_models"

# Remote debugging of PlaceOS apps, such as Booking Panel, Control and Signage.
# The apps find this driver from the `remote_debug` binding of the
# organisation zone. A device reads its `device:<id>` binding, sends logs with
# `post_logs` and sends command results with `command_result`. Fixed devices,
# such as panels and signage, also call `register` each 15 minutes so the admin
# views list them.
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

    Only support users can request logs and send commands. For the device
    methods, the first user that calls for a device ID owns that ID. The
    driver ignores device calls for that ID from other users until it
    removes the device.

    The driver cannot limit who reads its bindings. The devices need access
    to this system, so they can also read `devices`, `logs:<id>` and
    `results:<id>`.
    DESC

  # Most entries that the driver keeps for each device. The device keeps 8,000
  # entries, so `before` can get all of them
  MAX_DEVICE_ENTRIES = 8000
  # Most command results that the driver keeps for each device
  MAX_DEVICE_RESULTS = 50
  # Most devices that the driver keeps data for, and most devices with a request or commands
  MAX_DEVICES = 1000
  # Most commands for each device. The device reads the first 20
  MAX_COMMANDS = 20
  # Most keys in a `settings` command, and most characters in a key
  MAX_SETTINGS_KEYS =  50
  MAX_SETTINGS_KEY  = 200
  # Most characters in the path of a `navigate` command
  MAX_PATH = 2000
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
  SEEN_INTERVAL = 1.minute
  # Time without a call before the driver removes a device and its data. Also
  # the time that the driver keeps each entry and result after it gets them
  STALE_AFTER = 7.days
  DEVICE_ID   = /\A[A-Za-z0-9_-]{1,64}\z/

  # State of each device with a log request or commands
  @states = {} of String => RemoteDebugDeviceState
  # Devices that called the driver, by ID
  @devices = {} of String => RemoteDebugDevice
  # Whether `devices` has `last_seen` changes that are not written yet
  @devices_changed = false
  # User that first called for each device ID. Kept while the device is in
  # `devices` or has a request or commands
  @owners = {} of String => String
  @logs = {} of String => RemoteLogsView
  @results = {} of String => Array(RemoteDebugCommandResult)
  # Token and end timer of the active log requests, by device ID. Each timer
  # has a new token. The timer is `nil` until `schedule.in` returns
  @expiry = {} of String => {Int64, PlaceOS::Driver::Proxy::Scheduler::TaskWrapper?}
  @expiry_token = 0_i64
  # Timeout timers of the pending commands, by command ID
  @command_timers = {} of String => PlaceOS::Driver::Proxy::Scheduler::TaskWrapper

  def on_load
    self[:devices] = @devices
    schedule.every(SEEN_INTERVAL) { sweep_devices }
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
    # Replace the timer before the write, as the write lets other calls run
    start_expiry device_id, request.duration
    publish_state device_id
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
    # The device starts the duration again when the level changes
    start_expiry device_id, logs.duration
    publish_state device_id
  end

  # Ends the active log request of a device
  @[Security(Level::Support)]
  def stop_logs(device_id : String) : Nil
    cancel_expiry device_id
    state = @states[device_id]?
    return unless state && state.logs
    state.logs = nil
    publish_state device_id
  end

  # Adds a command for a device. Returns the command ID, or `nil` when the
  # device has `MAX_COMMANDS` commands already.
  # `options` holds the fields of the command, such as `keys`, `path` or `width`
  @[Security(Level::Support)]
  def send_command(device_id : String, type : RemoteDebugCommandType, options : RemoteDebugCommandOptions? = nil) : String?
    check_device_id device_id
    command = build_command(type, options || RemoteDebugCommandOptions.new)
    count = @states[device_id]?.try(&.commands.size) || 0
    return if count >= MAX_COMMANDS
    state_for(device_id).commands << command
    @command_timers[command.id] = schedule.in(COMMAND_TIMEOUT) do
      # Remove the timer first, so `take_command` does not cancel it
      @command_timers.delete(command.id)
      publish_state(device_id) if take_command(device_id, command.id)
    end
    publish_state device_id
    command.id
  end

  # ===================================
  # Methods that the devices call
  # ===================================

  # Adds or updates a fixed device in `devices`. Fixed devices call this each 15 minutes
  def register(device : RemoteDebugDevice) : Nil
    seen(device.id, device) if DEVICE_ID.matches?(device.id)
  end

  # Adds the entries of a device. Ignores calls for a request that is not
  # active, and calls from an app session before the last one
  def post_logs(device_id : String, request_id : String, entries : Array(RemoteLogEntry), device : RemoteDebugDevice) : Nil
    return unless device.id == device_id && accepts_logs?(device_id, request_id, device)
    return unless seen(device_id, device)
    # `seen` can write `devices`, which lets other calls run, so check again
    return unless owned?(device_id) && accepts_logs?(device_id, request_id, device)

    view = @logs[device_id]?
    # A new `started_at` shows that the app reloaded and `seq` started again
    same_session = view && view.device.started_at == device.started_at
    old = view && same_session ? view.entries : [] of RemoteLogEntry
    known = old.map(&.seq).to_set
    # The device sends a failed batch again, so skip the entries that we have
    added = entries.first(MAX_BATCH).reject { |entry| known.includes?(entry.seq) }.uniq!(&.seq)
    if view && same_session && added.empty?
      # Write the view again, so a retry repairs a write that failed. The
      # write does nothing when the binding has this value
      self["logs:#{device_id}"] = view
      return
    end

    received_at = now_ms
    added.map! { |entry| entry.received_at = received_at; entry }
    view = RemoteLogsView.new(device, (old + added).sort_by!(&.seq).last(MAX_DEVICE_ENTRIES))
    @logs[device_id] = view
    self["logs:#{device_id}"] = view
  end

  # Keeps the result of a command and removes the command
  def command_result(device_id : String, command_id : String, result : RemoteDebugResult, device : RemoteDebugDevice) : Nil
    pending = @states[device_id]?.try &.commands.any?(&.id.==(command_id))
    return unless pending && device.id == device_id
    return unless seen(device_id, device)
    # `seen` can write `devices`, which lets other calls run. Take the command
    # after it, so a second call for the same command does nothing
    return unless owned?(device_id)
    command = take_command(device_id, command_id)
    return unless command

    if result.to_json.size > MAX_RESULT_LENGTH
      result = RemoteDebugResult.new(ok: false, error: "Result is too large")
    end

    results = @results[device_id]? || [] of RemoteDebugCommandResult
    results << RemoteDebugCommandResult.new(command.id, command.type, result, now_ms)
    @results[device_id] = results = results.last(MAX_DEVICE_RESULTS)
    begin
      self["results:#{device_id}"] = results
    ensure
      # The command is not in memory now, so also remove it from the binding
      publish_state device_id
    end
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

  # Writes the `device:<id>` binding. An empty state is removed and shows as
  # `null`. Then the owner of a device that `forget` removed is also removed
  protected def publish_state(device_id : String) : Nil
    state = @states[device_id]?
    if state && state.empty?
      @states.delete(device_id)
      @owners.delete(device_id) unless @devices.has_key?(device_id)
      state = nil
    end
    self["device:#{device_id}"] = state
  end

  # Ends the log request of a device when its duration ends.
  # `schedule.in` can let other calls run, and its timer can run before it
  # returns. So the token is kept before the call, and a timer only ends the
  # request while its token is the current token
  protected def start_expiry(device_id : String, duration : Int32?) : Nil
    cancel_expiry device_id
    token = @expiry_token += 1
    @expiry[device_id] = {token, nil}
    timer = schedule.in((duration || DEFAULT_DURATION_MS).milliseconds) do
      if @expiry[device_id]?.try(&.[0]) == token
        @expiry.delete(device_id)
        stop_logs device_id
      end
    end
    if @expiry[device_id]?.try(&.[0]) == token
      @expiry[device_id] = {token, timer}
    else
      timer.cancel
    end
  end

  protected def cancel_expiry(device_id : String) : Nil
    @expiry.delete(device_id).try(&.[1]).try(&.cancel)
  end

  protected def build_command(type : RemoteDebugCommandType, options : RemoteDebugCommandOptions) : RemoteDebugCommand
    id = new_id
    case type
    in .settings?
      keys = options.keys
      raise ArgumentError.new("settings needs keys") unless keys
      raise ArgumentError.new("settings has #{MAX_SETTINGS_KEYS} keys maximum") if keys.size > MAX_SETTINGS_KEYS
      raise ArgumentError.new("a settings key has #{MAX_SETTINGS_KEY} characters maximum") if keys.any?(&.size.>(MAX_SETTINGS_KEY))
      RemoteDebugCommand.new(id, type, keys: keys)
    in .navigate?
      path = options.path
      raise ArgumentError.new("navigate needs a path that starts with /") unless path && path.starts_with?('/')
      raise ArgumentError.new("navigate has a path of #{MAX_PATH} characters maximum") if path.size > MAX_PATH
      RemoteDebugCommand.new(id, type, path: path)
    in .snapshot?
      RemoteDebugCommand.new(id, type, width: options.width)
    in .animation?
      RemoteDebugCommand.new(id, type, width: options.width, duration: options.duration, fps: options.fps, format: options.format)
    in .status?, .storage?, .reload?, .clear_cache?
      RemoteDebugCommand.new(id, type)
    end
  end

  # Whether the request is the active request of the device, and the call is
  # not from an app session before the session of the kept entries
  protected def accepts_logs?(device_id : String, request_id : String, device : RemoteDebugDevice) : Bool
    return false unless @states[device_id]?.try(&.logs).try(&.id) == request_id
    view = @logs[device_id]?
    !(view && device.started_at < view.device.started_at)
  end

  # Removes a command from the state, and stops its timeout. Does not write
  # the state. Returns the command, or `nil` when it is not pending
  protected def take_command(device_id : String, command_id : String) : RemoteDebugCommand?
    commands = @states[device_id]?.try &.commands
    index = commands.try &.index(&.id.==(command_id))
    return unless commands && index
    @command_timers.delete(command_id).try &.cancel
    commands.delete_at(index)
  end

  # Whether the caller owns the device ID, and the device is in `devices`
  protected def owned?(device_id : String) : Bool
    @devices.has_key?(device_id) && @owners[device_id]? == (invoked_by_user_id || "")
  end

  # Adds or updates a device in `devices`. Returns `false`, and does not
  # change the device, when the caller is not the user that owns the device ID.
  # Keeps the `MAX_DEVICES` devices that were seen last, and removes the data
  # of the other devices. Writes `devices` when a device changes.
  # `sweep_devices` writes the changes of `last_seen` only, so 1,000 fixed
  # devices do not write the list each second
  protected def seen(device_id : String, device : RemoteDebugDevice) : Bool
    # Calls from other drivers have no user
    user = invoked_by_user_id || ""
    return false unless (@owners[device_id] ||= user) == user

    previous = @devices[device_id]?
    # Compare all the fields but `last_seen`
    device.last_seen = previous.try &.last_seen
    changed = previous != device
    device.last_seen = now_ms
    @devices[device_id] = device

    if @devices.size > MAX_DEVICES
      forget @devices.min_by { |_id, item| item.last_seen || 0_i64 }[0]
      changed = true
    end

    changed ? publish_devices : (@devices_changed = true)
    true
  end

  protected def publish_devices : Nil
    @devices_changed = false
    self[:devices] = @devices
  end

  # Removes the devices that did not call for `STALE_AFTER`, and the entries
  # and results that the driver got more than `STALE_AFTER` ago. Writes the
  # changes of `last_seen`. Runs each `SEEN_INTERVAL`.
  # Each write lets other calls run, so it reads each device again before it
  # changes it
  protected def sweep_devices : Nil
    stale = now_ms - STALE_AFTER.total_milliseconds.to_i64
    @devices.keys.each do |device_id|
      device = @devices[device_id]?
      next unless device && (device.last_seen || 0_i64) < stale
      forget device_id
      @devices_changed = true
    end
    publish_devices if @devices_changed

    @logs.keys.each do |device_id|
      view = @logs[device_id]?
      next unless view
      count = view.entries.size
      view.entries.reject!(&.received_at.<(stale))
      next if view.entries.size == count
      if view.entries.empty?
        @logs.delete(device_id)
        self["logs:#{device_id}"] = nil
      else
        self["logs:#{device_id}"] = view
      end
    end

    @results.keys.each do |device_id|
      results = @results[device_id]?
      next unless results
      count = results.size
      results.reject!(&.received_at.<(stale))
      next if results.size == count
      if results.empty?
        @results.delete(device_id)
        self["results:#{device_id}"] = nil
      else
        self["results:#{device_id}"] = results
      end
    end
  end

  # Removes a device and its logs and results. Keeps the owner while the
  # device has a request or commands, so other users cannot send data for them
  protected def forget(device_id : String) : Nil
    @devices.delete(device_id)
    @owners.delete(device_id) unless @states.has_key?(device_id)
    @logs.delete(device_id)
    @results.delete(device_id)
    self["logs:#{device_id}"] = nil
    self["results:#{device_id}"] = nil
  end
end
