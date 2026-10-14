require "placeos-driver"

# A device whose state is set by whoever is testing it.
#
# Exists for end-to-end suites that need to watch a status travel from a module
# through redis, `source` and the MQTT broker into an app. The transport is UDP,
# which comes online without a peer to answer it, so the module reports
# `connected: true` as soon as it starts and changes only when told to.
#
# Talks to nothing. Point it at any address: `127.0.0.1` is fine.
class Place::E2E::StateHarness < PlaceOS::Driver
  descriptive_name "PlaceOS E2E State Harness"
  generic_name :Display
  description <<-DESC
    Test fixture. Its `connected` state and any other status are set by calling
    its functions, so an end-to-end suite can drive what a module reports.
    Sends nothing to the device it is pointed at.
    DESC

  udp_port 9

  # Marks the module online or offline, as a device that stopped answering
  # would be. The transport stays up, so this only changes what is reported.
  def set_connected(state : Bool) : Bool
    set_connected_state(state)
    state
  end

  # Sets any status to any JSON value
  def set_status(key : String, value : JSON::Any) : JSON::Any
    self[key] = value
    value
  end

  # Removes a status, as a driver does when a value no longer applies
  def clear_status(key : String) : Nil
    self[key] = nil
  end

  def received(data, task)
    task.try &.success
  end
end
