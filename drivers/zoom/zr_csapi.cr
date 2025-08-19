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

  getter? ready : Bool = false

  def on_load
    queue.wait = false
    queue.delay = 10.milliseconds
    @ready = false
  end

  def connected
    # we need to disconnect if we don't see welcome message
    schedule.in(20.seconds) do
      if !ready?
        logger.error { "ZR-CSAPI connection failed to be ready after 20 seconds." }
        disconnect
      end
    end
    logger.debug { "Connected to Zoom Room ZR-CSAPI on port 2244" }
    self[:connected] = true
    do_send("zStatus SystemUnit", name: "status_system_unit")
  end

  def disconnected
    logger.debug { "Disconnected from Zoom Room ZR-CSAPI" }
    @ready = false
    schedule.clear
    transport.tokenizer = nil
    self[:connected] = false
  end

  # Get today's meetings scheduled for this room
  def bookings_list
    do_send("zCommand Bookings List", name: "bookings_list")
  end

  # Update/refresh the meeting list from calendar
  def bookings_update
    do_send("zCommand Bookings Update", name: "bookings_update")
  end

  def received(data, task)
    response = String.new(data).strip
    logger.debug { "Received: #{response.inspect}" }
    unless ready?
      if data.includes?("ZAAPI")
        @ready = true
        transport.tokenizer = Tokenizer.new "\r\n"
        do_send("echo off", name: "echo_off")
        schedule.clear
        do_send("format json", name: "set_format")
        schedule.clear
      else
        return task.try(&.abort)
      end
    end

    task.try &.success(response)

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

  private def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send "#{command}\r\n", **options
  end
end
