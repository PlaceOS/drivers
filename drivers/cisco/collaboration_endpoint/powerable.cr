require "placeos-driver/interface/powerable"
require "./xapi"

module Cisco::CollaborationEndpoint::Powerable
  include PlaceOS::Driver::Interface::Powerable
  include Cisco::CollaborationEndpoint::XAPI

  alias Interface = PlaceOS::Driver::Interface

  # Powerable Interface:
  # ====================

  command({"Standby Deactivate" => :powerup})
  command({"Standby HalfWake" => :half_wake})
  command({"Standby Activate" => :standby})
  command({"Standby ResetTimer" => :reset_standby_timer}, delay: 1..480)

  def power(state : Bool)
    state ? powerup : half_wake
    self[:power] = state
  end

  def power_state(state : Interface::Powerable::PowerState)
    case state
    in .on?
      power true
    in .off?
      power false
    in .full_off?
      standby
      self[:power] = false
    end
    self[:power_state] = state
  end

  enum PowerOff
    Restart
    Shutdown
  end
end
