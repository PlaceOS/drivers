require "placeos-driver"

class Kaiterra::RoomLogic < PlaceOS::Driver
  descriptive_name "Room level abstraction of Kaiterra status "
  generic_name :RoomEnvironment
  description "Abstracts room sensors for Kaiterra"

  default_settings({
    kaiterra_room_id:          "Paste Kaiterra Room ID here",
    kaiterra_status_poll_cron: "*/5 * * * *",
  })

  accessor kaiterra : Kaiterra

  @room_id : String = ""
  @cron_string : String = "*/5 * * * *"

  def on_update
    @room_id = setting(String, :kaiterra_room_id)
    @cron_string = setting(String, :kaiterra_status_poll_cron)
    schedule.clear
    schedule.cron(@cron_string) { get_measurements }
  end

  def get_measurements
    response = kaiterra.get_devices(@room_id).get
    return "No Data" unless results = response.as_h["data"]
    results.as_a.each do |i|
      name = "#{i["param"]} (#{i["units"]})"
      value = i["points"].as_a.first["value"]
      self[name] = value
    end
  end
end
