require "placeos-driver"
require "./metasys_models"

class JohnsonControls::RoomLogic < PlaceOS::Driver
  descriptive_name "JCI Room Schedule Logic"
  generic_name :RoomLogic
  description %(Polls Johnson Controls Metasys API Module to expose object present value)

  default_settings({
    id: "set obcject ID here",
    polling_cron:                  "*/15 * * * *",
    debug:                         false,
  })

  accessor johnson_controls : Control

  @id : String = "set obcject ID here"
  @cron_string : String = "*/15 * * * *"
  @debug : Bool = false
  @next_countdown : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
  @request_lock : Mutex = Mutex.new
  @request_running : Bool = false

  def on_load
    on_update
  end

  def on_update
    @debug = setting(Bool, :debug) || false
    @id = setting(String, :id)
    @cron_string = setting(String, :polling_cron)
    schedule.clear
    schedule.cron(@cron_string, immediate: true) { fetch_present_value }
  end

  def fetch_present_value
    values = GetSingleObjectPresentValueResponse.from_json(johnson_controls.get_single_object_presentValue(@id).get.to_json)
    self["present_value"] = values.item.presentValue.value
  end
end

