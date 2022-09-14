require "placeos-driver"

class RHBAccess::AxiomRoomLogic < PlaceOS::Driver
  descriptive_name "Room Access Logic for Axiom rooms"
  generic_name :RoomAccess
  description "Abstracts room access for Axiom"

  default_settings({
    axiom_door_ids: [] of String,
    axiom_status_poll_cron:  "*/5 * * * *",
  })

  accessor axiom : AxiomXa

  @door_ids = [] of String
  @cron_string : String = "*/5 * * * *"

  def on_load
    on_update
  end

  def on_update
    @door_ids = setting(Array(String), :axiom_door_ids)
    @cron_string = setting(String, :axiom_status_poll_cron)
    schedule.clear
    schedule.cron(@cron_string) { status? }
  end

  def lock
    @door_ids.map { |d| axiom.lock(d).get }
  rescue
    logger.error {"AxiomXa: ERROR while LOCKING #{@door_ids}"}
  else
    self["locked_by_placeos_at"] = Time.local
    status?
  end

  def unlock
    @door_ids.map { |d| axiom.unlock(d).get }
  rescue
    logger.error {"AxiomXa: ERROR while UNLOCKING #{@door_ids}"}
  else
    self["unlocked_by_placeos_at"] = Time.local
    status?
  end

  def status?
    result = @door_ids.map { |id| {id, axiom.status?(id).get} }
  rescue
    logger.error {"AxiomXa: ERROR requesting STATUS of #{@door_ids}"}
  else
    result.map { |id, status| self[id] = status["Status"] }
    self["doors_locked"] = result.count { |status| status.includes? "Locked" }
  end
end
