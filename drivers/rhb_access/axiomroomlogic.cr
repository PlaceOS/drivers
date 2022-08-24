require "placeos-driver"

class RHBAccess::AxiomRoomLogic < PlaceOS::Driver
  descriptive_name "Room Access Logic for Axiom rooms"
  generic_name :RoomAccess
  description "Abstracts room access for Axiom"

  default_settings({
    axiom_door_ids: [] of String,
  })

  accessor axiom : AxiomXa

  @door_ids = [] of String

  def on_load
    on_update
  end

  def on_update
    @door_ids = setting(Array(String), :axiom_door_ids)
  end

  def lock
    @door_ids.map { |d| axiom.lock(d) }
    self["locked_at"] = Time.local
    self["doors_locked"] = true
  end

  def unlock
    @door_ids.map { |d| axiom.unlock(d) }
    self["unlocked_at"] = Time.local
    self["doors_locked"] = false
  end
end
