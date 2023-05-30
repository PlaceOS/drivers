require "placeos-driver"

class Place::Demo::LocationServices < PlaceOS::Driver
  descriptive_name "Demo Location Services"
  generic_name :LocationServices
  description %(a mock version of location services for demos and testing)

  default_settings({
    building_zone: "zone_123",
    level_zone:    "zone_456",
    system_id:     "sys-123",
  })

  @building_zone : String = ""
  @level_zone : String = ""
  @system_id : String = ""

  def on_load
    on_update
  end

  def on_update
    @building_zone = setting(String, :building_zone)
    @level_zone = setting(String, :level_zone)
    @system_id = setting(String, :system_id)
  end

  def locate_user(email : String? = nil, username : String? = nil)
    case rand(3)
    when 0
      [{
        location:         "wireless",
        coordinates_from: "bottom-left",
        x:                27.113065326953013,
        y:                36.85052447328469,
        lon:              55.27498749637098,
        lat:              25.20090608906493,
        mac:              "66e0fd1279ce",
        variance:         4.5194575835650745,
        last_seen:        1601555879,
        building:         @building_zone,
        level:            @level_zone,
        map_width:        1234.2,
        map_height:       123.8,
      }]
    when 1
      [{
        location: "meeting",
        mac:      "meeting.room@resource.org.com",
        event_id: "meet-1234567",
        map_id:   "map-1234",
        sys_id:   @system_id,
        ends_at:  1.hour.from_now,
        private:  false,
        level:    @level_zone,
        building: @building_zone,
      }]
    else
      [] of String
    end
  end
end
