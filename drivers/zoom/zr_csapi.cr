require "placeos-driver"

# Driver for Zoom Room ZR-CSAPI (Legacy SSH Control System API)
# Connects to Zoom Room machines via SSH on port 2244
# API Documentation: https://developers.zoom.us/docs/rooms/cli/
class Zoom::ZrCSAPI < PlaceOS::Driver
  descriptive_name "Zoom Room ZR-CSAPI"
  generic_name :ZoomRoomAPI
  description "Legacy SSH-based API for Zoom Rooms. Requires SSH credentials configured on the Zoom Room."

  tcp_port 2244

  default_settings({
    ssh: {
      username: "zoom",
      password: "",
    },
  })

  def on_load
  end

  def on_update
  end

  def connected
    logger.debug { "Connected to Zoom Room ZR-CSAPI on port 2244" }
    self[:connected] = true
    initialize_ssh_session
    send("zStatus SystemUnit\n", name: "status_system_unit")
  end

  def disconnected
    logger.debug { "Disconnected from Zoom Room ZR-CSAPI" }
    self[:connected] = false
    schedule.clear
  end

  def initialize_ssh_session
    send("echo off\n", name: "echo_off")
    send("format json\n", name: "set_format")
  end

  # Get today's meetings scheduled for this room
  def bookings_list
    send("zCommand Bookings List\n", name: "bookings_list")
  end

  # Update/refresh the meeting list from calendar
  def bookings_update
    send("zCommand Bookings Update\n", name: "bookings_update")
  end

  def received(data, task)
    response = String.new(data).strip
    logger.debug { "Received: #{response}" }
    
    if response[0] != '{'
      return
    end

    json_response = JSON.parse(response)
    response_type = json_response["type"]
    response_topkey = json_response["topKey"]

    case response_type
    when "zStatus"
      case response_topkey
      when "SystemUnit"
        self[:system_unit] = json_response["SystemUnit"]
      end
    when "zCommand"
      case response_topkey
      when "Bookings List"
        self[:bookings_list] = json_response["Bookings List"]
      when "Bookings Update"
        self[:bookings_last_updated_at] = Time.local.to_s
      end
    when "zEvent"
      case response_topkey
      when "Bookings Update"
        self[:bookings_last_updated_at] = Time.local.to_s
      end
    end
  end
end