require "placeos-driver"
require "./remote_setup_models"

# Lets a person set up a Booking Panel, Control or Signage device from a phone.
#
# Devices call `register` and wait for a command in the `device_<id>` binding.
# The setup flow (Concierge or Signage Manager) calls `configure` or `clear`.
# The device applies the command and calls `complete`.
#
# Interface: https://github.com/PlaceOS/user-interfaces/blob/develop/docs/remote-setup.md
class Place::RemoteSetup < PlaceOS::Driver
  include RemoteSetupModels

  descriptive_name "PlaceOS Remote Setup"
  generic_name :RemoteSetup
  description %(Passes setup commands from the Concierge and Signage Manager setup flow to Booking Panel, Control and Signage devices.
    To turn it on, add `"remote_setup": {"system_id": "<id of this system>"}` to the authority config of the domain.)

  default_settings({
    # remove devices that did not call `register` or `complete` in this time
    device_ttl_hours: 168,
    # remove commands that a device did not complete in this time
    command_ttl_minutes: 15,
  })

  # Most devices in the `devices` binding
  MAX_DEVICES = 1000
  # Most time between a change and the `devices` binding update
  PUBLISH_INTERVAL = 1.second

  @devices = {} of String => Device
  # Pending command of each device, by device ID
  @commands = {} of String => Command
  @device_ttl : Time::Span = 7.days
  @command_ttl : Time::Span = 15.minutes
  # The `devices` binding is out of date and must be published
  @devices_changed = false
  # Only `last_seen` is out of date. Published by `remove_stale`
  @last_seen_changed = false

  def on_load
    self[:devices] = @devices
    self[:connected] = true
    on_update

    # A large fleet can register many devices at the same time, such as after
    # a restart. So changes are published together at most once per interval.
    schedule.every(PUBLISH_INTERVAL) { publish_devices }
    schedule.every(1.minute) { remove_stale }
  end

  def on_update
    @device_ttl = (setting?(Int32, :device_ttl_hours) || 168).clamp(0, 24 * 365).hours
    @command_ttl = (setting?(Int32, :command_ttl_minutes) || 15).clamp(0, 24 * 60).minutes
  end

  # Called by a device when the driver connects, and then every 15 minutes
  def register(device_id : String, app : App, config : Config? = nil) : Nil
    RemoteSetupModels.check_id("device_id", device_id)
    config.try &.validate!
    now = Time.utc.to_unix_ms

    if device = @devices[device_id]?
      if device.app == app && device.config == config
        # A heartbeat. `remove_stale` publishes the new `last_seen`
        @last_seen_changed = true
      else
        device.app = app
        device.config = config
        @devices_changed = true
      end
      device.last_seen = now
    else
      @devices[device_id] = Device.new(device_id, app, config, now)
      @devices_changed = true
      remove_oldest_devices
    end
  end

  # Called by the setup flow. Returns the command ID
  @[Security(Level::Support)]
  def configure(device_id : String, config : Config) : String
    config.validate!
    logger.info { "#{invoked_by_user_id} configured #{device_id} with #{config.to_json}" }
    send_command(device_id, Command.new(Action::Configure, config, Time.utc.to_unix_ms))
  end

  # Called by the setup flow. Returns the command ID
  @[Security(Level::Support)]
  def clear(device_id : String) : String
    logger.info { "#{invoked_by_user_id} cleared #{device_id}" }
    send_command(device_id, Command.new(Action::Clear, nil, Time.utc.to_unix_ms))
  end

  # Called by a device after it applies a command
  def complete(device_id : String, command_id : String) : Nil
    command = @commands[device_id]?
    return unless command && command.id == command_id

    remove_command(device_id)
    if device = @devices[device_id]?
      device.config = command.config
      device.last_command = command.id
      device.last_seen = Time.utc.to_unix_ms
      @devices_changed = true
    end
  end

  # Remove stale devices and commands. Runs every minute
  def remove_stale : Nil
    now = Time.utc
    device_cutoff = (now - @device_ttl).to_unix_ms
    command_cutoff = (now - @command_ttl).to_unix_ms

    @commands.select { |_id, command| command.issued_at <= command_cutoff }.each_key { |id| remove_command(id) }
    @devices.select { |_id, device| device.last_seen <= device_cutoff }.each_key { |id| remove_device(id) }

    @devices_changed ||= @last_seen_changed
    publish_devices
  end

  private def send_command(device_id : String, command : Command) : String
    raise ArgumentError.new("device not found: #{device_id}") unless @devices.has_key?(device_id)
    @commands[device_id] = command
    self[command_binding(device_id)] = command
    command.id
  end

  private def remove_command(device_id : String) : Nil
    # Setting `nil` deletes the binding and signals `null`
    self[command_binding(device_id)] = nil if @commands.delete(device_id)
  end

  private def remove_device(device_id : String) : Nil
    @devices.delete(device_id)
    remove_command(device_id)
    @devices_changed = true
  end

  # Keep `MAX_DEVICES` maximum. Devices are added one at a time, so this
  # removes one device at most.
  private def remove_oldest_devices : Nil
    while @devices.size > MAX_DEVICES
      remove_device(@devices.min_by { |_id, device| device.last_seen }[0])
    end
  end

  private def publish_devices : Nil
    return unless @devices_changed
    @devices_changed = false
    @last_seen_changed = false
    self[:devices] = @devices
  end

  private def command_binding(device_id : String) : String
    "device_#{device_id}"
  end
end
