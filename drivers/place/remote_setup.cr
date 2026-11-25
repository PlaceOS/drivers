require "placeos-driver"
require "./remote_setup_models"

# Lets a person set up a Booking Panel, Control or Signage device from a phone.
#
# A device on its setup screen calls `register`. The setup flow (Concierge or
# Signage Manager) calls `configure`, which puts a command in the `device_<id>`
# binding. The device applies the command and calls `complete`. A device that
# is set up also applies commands, so `configure` and `complete` work for
# devices that did not register.
#
# A device that is set up clears its configuration when its ID is in
# `clear_list` (from `clear`), or when its app and system are in
# `clear_systems` (from `clear_system`).
#
# To find the ID of a device that is set up, `show_device_ids` asks devices to
# show their ID for a short time, through the `show_ids` binding.
#
# Interface: https://github.com/PlaceOS/user-interfaces/blob/develop/docs/remote-setup.md
class Place::RemoteSetup < PlaceOS::Driver
  include RemoteSetupModels

  descriptive_name "PlaceOS Remote Setup"
  generic_name :RemoteSetup
  description %(Passes setup changes from the Concierge and Signage Manager setup flow to Booking Panel, Control and Signage devices.
    To turn it on, add `"remote_setup": {"system_id": "<id of this system>"}` to the authority config of the domain.)

  default_settings({
    # remove devices that did not call `register` or `complete`, and `clear_list` IDs, after this time
    device_ttl_hours: 168,
    # remove configure commands that a device did not complete after this time
    command_ttl_minutes: 15,
  })

  # Most entries in each of `devices`, pending commands, `clear_list`, `clear_systems` and `show_ids`
  MAX_ENTRIES = 1000
  # Most time that `show_device_ids` can ask devices to show their ID
  MAX_SHOW_IDS_SECONDS = 15 * 60
  # Time that devices have to apply a `clear_systems` entry. Fixed by the interface
  SYSTEM_CLEAR_TTL = 15.minutes
  # Time between binding updates. Heartbeat-only `devices` changes wait for `remove_stale`
  PUBLISH_INTERVAL = 1.second

  # Bindings other than `device_<id>`. Setup flow calls publish their change at once, so the flow
  # sees it. Device and cleanup changes are published together by the
  # one-second task.
  enum Binding
    Devices
    ClearList
    ClearSystems
    ShowIds
  end

  # Each call runs in its own fiber, and binding writes yield to Redis. Calls
  # and scheduled tasks hold this lock, so state and bindings change together.
  @lock = Mutex.new

  @devices = {} of String => Device
  # Pending configure command of each device, by device ID. Oldest first
  @commands = {} of String => Command
  # IDs of the devices to clear, with the time they were added. Oldest first
  @clear_list = {} of String => Int64
  # Oldest first
  @clear_systems = [] of SystemClear
  # Oldest first
  @show_ids = [] of ShowIds
  @device_ttl : Time::Span = 7.days
  @command_ttl : Time::Span = 15.minutes
  # Bindings that are out of date. A failed write stays here for the next tick
  @changed = Set(Binding).new
  # Only `last_seen` is out of date. `remove_stale` marks `devices` for publishing
  @last_seen_changed = false

  def on_load
    on_update

    # Many devices can register at the same time. So changes are published
    # together at most once per interval.
    schedule.every(PUBLISH_INTERVAL) { @lock.synchronize { publish_changes } }
    schedule.every(1.minute) { remove_stale }

    # The one-second task tries a failed first write again. The driver manager
    # sets `connected` after `on_load`, so a device can see it up to one tick
    # before a failed list write is published. Devices read a missing list as empty.
    @lock.synchronize do
      Binding.each { |binding| @changed << binding }
      publish_changes
    end
  end

  def on_update
    @device_ttl = (setting?(Int32, :device_ttl_hours) || 168).clamp(0, 24 * 365).hours
    @command_ttl = (setting?(Int32, :command_ttl_minutes) || 15).clamp(0, 24 * 60).minutes
  end

  # Called by a device while it shows its setup screen, then every 15 minutes
  def register(device_id : String, app : App) : Nil
    RemoteSetupModels.check_id("device_id", device_id)
    @lock.synchronize do
      now = Time.utc.to_unix_ms
      if device = @devices[device_id]?
        if device.app == app && device.config.nil?
          # A heartbeat. `remove_stale` marks the new `last_seen` for publishing
          @last_seen_changed = true
        else
          device.app = app
          device.config = nil
          @changed << Binding::Devices
        end
        device.last_seen = now
      else
        @devices[device_id] = Device.new(device_id, app, now)
        @changed << Binding::Devices
        remove_oldest_devices
      end

      # The device shows its setup screen, so a clear is done
      @changed << Binding::ClearList if @clear_list.delete(device_id)
    end
  end

  # Called by the setup flow. Returns the command ID. The device does not have
  # to be in `devices`, because a device that is set up does not register.
  @[Security(Level::Support)]
  def configure(device_id : String, config : Config) : String
    RemoteSetupModels.check_id("device_id", device_id)
    config.validate!
    logger.info { "#{invoked_by_user_id} configured #{device_id} with #{config.to_json}" }

    @lock.synchronize do
      # Make room first, so that a failed write cannot take the list over the limit
      if !@commands.has_key?(device_id) && @commands.size >= MAX_ENTRIES
        remove_command(@commands.first_key)
      end
      command = Command.new(config, Time.utc.to_unix_ms)
      # Record first, so that `remove_stale` can remove a binding that a failed call wrote.
      # Delete first, so that the command moves to the end.
      @commands.delete(device_id)
      @commands[device_id] = command
      self[command_binding(device_id)] = command
      command.id
    end
  end

  # Called by the setup flow. The device does not have to be in `devices`,
  # because a device that is set up does not register.
  @[Security(Level::Support)]
  def clear(device_id : String) : Nil
    RemoteSetupModels.check_id("device_id", device_id)
    logger.info { "#{invoked_by_user_id} cleared #{device_id}" }

    @lock.synchronize do
      # Delete first, so that the ID moves to the end of the list
      @clear_list.delete(device_id)
      @clear_list[device_id] = Time.utc.to_unix_ms
      @clear_list.shift if @clear_list.size > MAX_ENTRIES
      # The flow waits to see the ID in the list, so a quick `register` must not hide it
      publish(Binding::ClearList)
    end
  end

  # Called by the setup flow. Devices of `app` that show `system_id` clear
  @[Security(Level::Support)]
  def clear_system(app : App, system_id : String) : Nil
    RemoteSetupModels.check_id("system_id", system_id)
    logger.info { "#{invoked_by_user_id} cleared #{app.to_json} devices of #{system_id}" }

    @lock.synchronize do
      @clear_systems << SystemClear.new(app, system_id, Time.utc.to_unix_ms)
      @clear_systems.shift if @clear_systems.size > MAX_ENTRIES
      publish(Binding::ClearSystems)
    end
  end

  # Called by the setup flow. Devices of `app` that show `system_id` show their
  # device ID for `seconds`. A `nil` argument does not filter on that field, so
  # with both `nil` all devices show their ID.
  @[Security(Level::Support)]
  def show_device_ids(app : App? = nil, system_id : String? = nil, seconds : Int32 = 60) : Nil
    system_id.try { |id| RemoteSetupModels.check_id("system_id", id) }
    logger.info { "#{invoked_by_user_id} showed device IDs of app: #{app.to_json}, system: #{system_id.to_json}" }

    @lock.synchronize do
      now = Time.utc
      expires_at = now + seconds.clamp(1, MAX_SHOW_IDS_SECONDS).seconds
      @show_ids << ShowIds.new(app, system_id, now.to_unix_ms, expires_at.to_unix_ms)
      @show_ids.shift if @show_ids.size > MAX_ENTRIES
      publish(Binding::ShowIds)
    end
  end

  # Called by a device after it applies a configure command. The command is
  # removed in all cases, but a device that is not in `devices` is added only
  # when it sends its `app`.
  def complete(device_id : String, command_id : String, app : App? = nil) : Nil
    @lock.synchronize do
      command = @commands[device_id]?
      next unless command && command.id == command_id

      now = Time.utc.to_unix_ms
      device = @devices[device_id]?
      if device.nil? && app
        device = @devices[device_id] = Device.new(device_id, app, now)
        remove_oldest_devices
      end
      if device
        device.config = command.config
        device.last_command = command.id
        device.last_seen = now
        @changed << Binding::Devices
      end
      remove_command(device_id)
    end
  end

  # Remove stale devices, commands and clears, and expired `show_ids`. Runs
  # every minute. Public so that specs and support users can run it at once.
  @[Security(Level::Support)]
  def remove_stale : Nil
    @lock.synchronize do
      now = Time.utc
      now_ms = now.to_unix_ms
      device_cutoff = (now - @device_ttl).to_unix_ms
      command_cutoff = (now - @command_ttl).to_unix_ms
      system_clear_cutoff = (now - SYSTEM_CLEAR_TTL).to_unix_ms

      @commands.select { |_id, command| command.issued_at <= command_cutoff }.each_key { |id| remove_command(id) }
      @devices.select { |_id, device| device.last_seen <= device_cutoff }.each_key { |id| remove_device(id) }
      @changed << Binding::Devices if @last_seen_changed

      # `reject!` returns the collection, so compare sizes to find a change
      size = @clear_list.size
      @clear_list.reject! { |_id, added_at| added_at <= device_cutoff }
      @changed << Binding::ClearList if @clear_list.size != size

      size = @clear_systems.size
      @clear_systems.reject! { |entry| entry.issued_at <= system_clear_cutoff }
      @changed << Binding::ClearSystems if @clear_systems.size != size

      size = @show_ids.size
      @show_ids.reject! { |entry| entry.expires_at <= now_ms }
      @changed << Binding::ShowIds if @show_ids.size != size
    end
  end

  # Delete the binding first, so that a failed write keeps the command for the
  # next `remove_stale`. Setting `nil` deletes the binding and signals `null`.
  private def remove_command(device_id : String) : Nil
    self[command_binding(device_id)] = nil
    @commands.delete(device_id)
  end

  # A pending command stays, because a device that is set up can apply it
  private def remove_device(device_id : String) : Nil
    @devices.delete(device_id)
    @changed << Binding::Devices
  end

  # Keep `MAX_ENTRIES` devices maximum. Devices are added one at a time, so
  # one removal is enough.
  private def remove_oldest_devices : Nil
    return unless @devices.size > MAX_ENTRIES
    remove_device(@devices.min_by { |_id, device| device.last_seen }[0])
  end

  private def publish_changes : Nil
    @changed.to_a.each { |binding| publish(binding) }
  end

  # Write a binding now. It leaves `@changed` only after the write, so a
  # failed write is tried again on the next tick.
  private def publish(binding : Binding) : Nil
    @changed << binding
    case binding
    in .devices?       then self[:devices] = @devices
    in .clear_list?    then self[:clear_list] = @clear_list.keys
    in .clear_systems? then self[:clear_systems] = @clear_systems
    in .show_ids?      then self[:show_ids] = @show_ids
    end
    @changed.delete(binding)
    @last_seen_changed = false if binding.devices?
  end

  private def command_binding(device_id : String) : String
    "device_#{device_id}"
  end
end
