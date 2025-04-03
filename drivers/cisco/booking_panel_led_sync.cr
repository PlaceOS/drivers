require "placeos-driver"

class Cisco::BookingPanelLedSync < PlaceOS::Driver
  descriptive_name "Cisco Webex Navigator Panel LED Sync"
  generic_name :Navigator_LED_Sync
  description "Sync Cisco Webex Navigator Panel LED to Bookings.in_use status"

  default_settings({
    led_color_when_room_booked: "Red",
    led_color_when_room_available: "Green",
    webex_panel_device_id: "Ensure this is set in each System's settings"
  })

  accessor webex_xapi : CloudXAPI
  accessor room_bookings : Bookings

  @led_color_when_room_booked : String = "Red"
  @led_color_when_room_available : String = "Green"
  @webex_panel_device_id : String = "Ensure this is set in each System's settings"

  def on_load
    on_update
    sync_led_color_now
  end

  def on_update
    clear_subscriptions
    @led_color_when_room_booked = setting(:led_color_when_room_booked) || "Red"
    @led_color_when_room_available = setting(:led_color_when_room_available) || "Green"
    @webex_panel_device_id = setting(:webex_panel_device_id) || "Ensure this is set in each System's settings"

    system.subscribe("Bookings_1", "in_use") do |_sub, value|
      next unless ["true", "false"].includes?(value)
      self[:room_in_use] = room_in_use = value == "true"
      set_led_color(room_in_use)
    end
  end

  def sync_led_color_now
    return unless ["true", "false"].includes?(room_in_use = system[:Bookings][:in_use].as_bool)
    set_led_color(room_in_use)
  end

  private def set_led_color(room_in_use : Bool)
    new_led_color = room_in_use ? @led_color_when_room_booked : @led_color_when_room_available
    webex_xapi.led_colour(@webex_panel_device_id, new_led_color)
    self[:led_color] = new_led_color
  end
end
