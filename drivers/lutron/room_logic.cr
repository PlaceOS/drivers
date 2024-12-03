require "placeos-driver"

# Currently this logic driver is designed for Quantum only but ideally there should be just one Lutron room logic that handles all Lutron APIs
class Lutron::RoomLogic < PlaceOS::Driver
  descriptive_name "Lutron Room level status "
  generic_name :RoomLighting
  description "Exposes the room's lighting state"

  default_settings({
    lutron_area_id:          0,
    lutron_status_poll_cron: "*/5 * * * *",
  })

  accessor lutron : Lutron

  @area_id : Int32 = 0
  @cron_string : String = "*/5 * * * *"

  def on_update
    @area_id = setting(Int32, :lutron_area_id)
    @cron_string = setting(String, :lutron_status_poll_cron)
    schedule.clear
    schedule.cron(@cron_string) { get_state }
  end

  def get_state
    self["lighting_scene"] = lutron.scene?(@area_id).get
    self["occupancy"] = lutron.occupancy_status?(@area_id).get
  end
end
