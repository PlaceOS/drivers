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
    # remove configure commands that a device did not complete, and `clear_systems` entries, after this time
    command_ttl_minutes: 15,
  })

  # Most entries in each of `devices`, pending commands, `clear_list` and `clear_systems`
  MAX_ENTRIES = 1000
  # Most time between a change and the `devices` binding update
  PUBLISH_INTERVAL = 1.second

  @devices = {} of String => Device
  # Pending configure command of each device, by device ID. Oldest first
  @commands = {} of String => Command
  # IDs of the devices to clear, with the time they were added. Oldest first
  @clear_list = {} of String => Int64
  # Oldest first
  @clear_systems = [] of SystemClear
  @device_ttl : Time::Span = 7.days
  @command_ttl : Time::Span = 15.minutes
  # The `devices` binding is out of date and must be published
  @devices_changed = false
  # Only `last_seen` is out of date. Published by `remove_stale`
  @last_seen_changed = false

  def on_load
    self[:devices] = @devices
    publish_clear_list
    publish_clear_systems
    self[:connected] = true
    on_update

    # Many devices can register at the same time. So `devices` changes are
    # published together at most once per interval.
    schedule.every(PUBLISH_INTERVAL) { publish_devices }
    schedule.every(1.minute) { remove_stale }
  end

  def on_update
    @device_ttl = (setting?(Int32, :device_ttl_hours) || 168).clamp(0, 24 * 365).hours
    @command_ttl = (setting?(Int32, :command_ttl_minutes) || 15).clamp(0, 24 * 60).minutes
  end

  # Called by a device while it shows its setup screen, then every 15 minutes
  def register(device_id : String, app : App) : Nil
    RemoteSetupModels.check_id("device_id", device_id)
    now = Time.utc.to_unix_ms

    if device = @devices[device_id]?
      if device.app == app && device.config.nil?
        # A heartbeat. `remove_stale` publishes the new `last_seen`
        @last_seen_changed = true
      else
        device.app = app
        device.config = nil
        @devices_changed = true
      end
      device.last_seen = now
    else
      @devices[device_id] = Device.new(device_id, app, now)
      @devices_changed = true
      remove_oldest_devices
    end

    # The device shows its setup screen, so a clear is done
    publish_clear_list if @clear_list.delete(device_id)
  end

  # Called by the setup flow. Returns the command ID. The device does not have
  # to be in `devices`, because a device that is set up does not register.
  @[Security(Level::Support)]
  def configure(device_id : String, config : Config) : String
    RemoteSetupModels.check_id("device_id", device_id)
    config.validate!
    logger.info { "#{invoked_by_user_id} configured #{device_id} with #{config.to_json}" }

    command = Command.new(config, Time.utc.to_unix_ms)
    # Delete first, so that the command moves to the end
    @commands.delete(device_id)
    @commands[device_id] = command
    self[command_binding(device_id)] = command
    remove_command(@commands.first_key) if @commands.size > MAX_ENTRIES
    command.id
  end

  # Called by the setup flow. The device does not have to be in `devices`,
  # because a device that is set up does not register.
  @[Security(Level::Support)]
  def clear(device_id : String) : Nil
    RemoteSetupModels.check_id("device_id", device_id)
    logger.info { "#{invoked_by_user_id} cleared #{device_id}" }

    # Delete first, so that the ID moves to the end of the list
    @clear_list.delete(device_id)
    @clear_list[device_id] = Time.utc.to_unix_ms
    @clear_list.shift if @clear_list.size > MAX_ENTRIES
    publish_clear_list
  end

  # Called by the setup flow. Devices of `app` that show `system_id` clear
  @[Security(Level::Support)]
  def clear_system(app : App, system_id : String) : Nil
    RemoteSetupModels.check_id("system_id", system_id)
    logger.info { "#{invoked_by_user_id} cleared #{app.to_json} devices of #{system_id}" }

    @clear_systems << SystemClear.new(app, system_id, Time.utc.to_unix_ms)
    @clear_systems.shift if @clear_systems.size > MAX_ENTRIES
    publish_clear_systems
  end

  # Called by a device after it applies a configure command. `app` adds a
  # device that did not register to `devices`.
  def complete(device_id : String, command_id : String, app : App? = nil) : Nil
    command = @commands[device_id]?
    return unless command && command.id == command_id

    remove_command(device_id)
    now = Time.utc.to_unix_ms
    device = @devices[device_id]?
    if device.nil? && app
      device = @devices[device_id] = Device.new(device_id, app, now)
      remove_oldest_devices
    end
    return unless device

    device.config = command.config
    device.last_command = command.id
    device.last_seen = now
    @devices_changed = true
  end

  # Remove stale devices, commands and clears. Runs every minute
  def remove_stale : Nil
    now = Time.utc
    device_cutoff = (now - @device_ttl).to_unix_ms
    command_cutoff = (now - @command_ttl).to_unix_ms

    @commands.select { |_id, command| command.issued_at <= command_cutoff }.each_key { |id| remove_command(id) }
    @devices.select { |_id, device| device.last_seen <= device_cutoff }.each_key { |id| remove_device(id) }

    clear_list_size = @clear_list.size
    @clear_list.reject! { |_id, added_at| added_at <= device_cutoff }
    publish_clear_list if @clear_list.size != clear_list_size

    clear_systems_size = @clear_systems.size
    @clear_systems.reject! { |entry| entry.issued_at <= command_cutoff }
    publish_clear_systems if @clear_systems.size != clear_systems_size

    @devices_changed ||= @last_seen_changed
    publish_devices
  end

  private def remove_command(device_id : String) : Nil
    # Setting `nil` deletes the binding and signals `null`
    self[command_binding(device_id)] = nil if @commands.delete(device_id)
  end

  # A pending command stays, because a device that is set up can apply it
  private def remove_device(device_id : String) : Nil
    @devices.delete(device_id)
    @devices_changed = true
  end

  # Keep `MAX_ENTRIES` devices maximum. Devices are added one at a time, so
  # this removes one device at most.
  private def remove_oldest_devices : Nil
    while @devices.size > MAX_ENTRIES
      remove_device(@devices.min_by { |_id, device| device.last_seen }[0])
    end
  end

  private def publish_devices : Nil
    return unless @devices_changed
    @devices_changed = false
    @last_seen_changed = false
    self[:devices] = @devices
  end

  private def publish_clear_list : Nil
    self[:clear_list] = @clear_list.keys
  end

  private def publish_clear_systems : Nil
    self[:clear_systems] = @clear_systems
  end

  private def command_binding(device_id : String) : String
    "device_#{device_id}"
  end
end
