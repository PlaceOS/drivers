require "placeos-driver"

class Kaiterra::RoomLogic < PlaceOS::Driver
  descriptive_name "Room level abstraction of Kaiterra status "
  generic_name :RoomEnvironment
  description "Abstracts room sensors for Kaiterra"

  default_settings({
    kaiterra_room_id: "Paste Kaiterra Room ID here",
    kaiterra_status_poll_cron:  "*/5 * * * *",
  })

  accessor kaiterra : Kaiterra

  @room_id : String = ""
  @cron_string : String = "*/5 * * * *"

  def on_load
    on_update
  end

  def on_update
    @room_id = setting(String, :kaiterra_room_id)
    @cron_string = setting(String, :kaiterra_status_poll_cron)
    schedule.cron(@cron_string) { get_measurements }
  end

  def get_measurements
    response = kaiterra.get_devices(@room_id).get
    return "No Data" unless response["data"]
    results = response["data"].as_a.map { |i| { "#{i["param"]} (#{i["units"]})", i.dig("points", "value") } }
    results.map { |measurement, value| self[measurement] = value }
  end
end
