require "placeos-driver"

# Driver for Zoom Room ZR-CSAPI (Legacy SSH Control System API)
# Connects to Zoom Room machines via SSH on port 2244
# API Documentation: https://developers.zoom.us/docs/rooms/cli/
class Zoom::ZrCSAPI < PlaceOS::Driver
  descriptive_name "Zoom Room ZR-CSAPI"
  generic_name :ZoomCSAPI
  description "Legacy SSH-based API for Zoom Rooms. Requires SSH credentials configured on the Zoom Room."

  tcp_port 2244

  default_settings({
    ssh: {
      username: "zoom",
      password: "",
    },
    enable_debug_logging: false
  })

  getter? ready : Bool = false
  @debug_enabled : Bool = false

  def on_load
    queue.wait = false
    queue.delay = 10.milliseconds
    self[:ready] = @ready = false
    on_update
  end

  def on_update
    @debug_enabled = setting?(Bool, :enable_debug_logging) || false
  end

  def connected
    reset_connection_flags
    # schedule.in(5.seconds) do
    #   initialize_tokenizer unless @ready || @init_called
    # end
    # we need to disconnect if we don't see welcome message
    schedule.in(9.seconds) do
      if !ready?
        logger.error { "ZR-CSAPI connection failed to be ready after 9 seconds." }
        disconnect
      end
    end
    logger.debug { "Connected to Zoom Room ZR-CSAPI" }
    self[:connected] = true
  end

  def disconnected
    reset_connection_flags
    queue.clear abort_current: true
    schedule.clear
    logger.debug { "Disconnected from Zoom Room ZR-CSAPI" }
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

  def system_unit?
    do_send("zStatus SystemUnit", name: "status_system_unit")
  end

  def send_command_r(command : String)
      transport.send "#{command}\r"
  end

  def send_command_n(command : String)
      transport.send "#{command}\n"
  end

  def send_command_rn(command : String)
      transport.send "#{command}\r\n"
  end

  protected def reset_connection_flags
    self[:ready] = @ready = false
    @init_called = false
    transport.tokenizer = nil
  end

  # Regexp's for tokenizing the ZR-CSAPI response structure.
  INVALID_COMMAND = /(?<=onUnsupported Command)[\r\n]+/
  SUCCESS = /(?<=OK)[\r\n]+/
  COMMAND_RESPONSE = Regex.union(INVALID_COMMAND, SUCCESS)
  private def initialize_tokenizer
    @init_called = true
    transport.tokenizer = Tokenizer.new do |io|
      raw = io.gets_to_end
      data = raw.lstrip
      index = if data.includes?("{")
                logger.debug { "Tokenizing as JSON response" } if @debug_enabled
                count = 0
                pos = 0
                data.each_char_with_index do |char, i|
                  pos = i
                  count += 1 if char == '{'
                  count -= 1 if char == '}'
                  break if count.zero?
                end
                pos if count.zero?
              else
                logger.debug { "Tokenizing as non-JSON response" } if @debug_enabled
                data =~ COMMAND_RESPONSE
              end
      if index
        message = data[0..index]
        index += raw.byte_index_to_char_index(raw.byte_index(message).not_nil!).not_nil!
        index = raw.char_index_to_byte_index(index + 1)
      end
      index || -1
    end
    self[:ready] = @ready = true
  rescue error
    @init_called = false
    logger.warn(exception: error) { "error configuring zrcsapi transport" }
  end

  def received(data, task)
    response = String.new(data).strip
    logger.debug { "Received: #{response.inspect}" } if @debug_enabled

    unless ready?
      if response.includes?("ZAAPI") # Initial connection message
        queue.clear abort_current: true
        sleep 1000.milliseconds
        logger.debug { "Disabling echo and enabling JSON output..." } if @debug_enabled
        do_send("echo off", name: "echo_off")
        schedule.clear
        do_send("format json", name: "set_format")
        schedule.clear
        sleep 1000.milliseconds
        initialize_tokenizer unless @init_called
      else
        return task.try(&.abort)
      end
    end

    task.try &.success(response)

    if response[0] != '{'
      return
    end

    logger.debug { "Parsing response into JSON..." } if @debug_enabled
    json_response = JSON.parse(response)
    response_type : String = json_response["type"].as_s
    response_topkey : String  = json_response["topKey"].as_s
    if @debug_enabled
      logger.debug { "JSON: #{json_response.inspect}" }
      logger.debug { "type: #{response_type}, topkey: #{response_topkey}" }
    end

    case response_type
    when "zStatus"
      case response_topkey
      when "SystemUnit"
        self[:system_unit] = json_response["SystemUnit"]
      end
    when "zCommand"
      case response_topkey
      when "BookingsUpdateResult"
        self[:bookings_last_updated_at] = Time.local.to_s
      end
    when "zEvent"
      case response_topkey
      when "BookingsUpdateResult"
        self[:bookings_last_updated_at] = Time.local.to_s
      when "BookingsListResult"
        self[:bookings_list] = json_response["BookingsListResult"]
      end
    end
  end

  private def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send "#{command}\r\n", **options
  end
end
