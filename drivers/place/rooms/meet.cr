require "placeos-driver"
require "../router"

class Place::Rooms::Meet < PlaceOS::Driver
  generic_name :System
  descriptive_name "Room logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction devices, systems and
    integrations found within common workplace collaboration spaces. It's
    behavior will adapt to match the capabilities and configuration of other
    drivers present in the same system.
    DESC

  def on_load
    on_update
  end


  def on_update
  end

  include Place::Router::Core
end
