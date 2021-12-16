require "placeos-driver"
require "./vive_leap_models"
require "placeos-driver/interface/sensor"

class Lutron::ViveLeap < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Lutron Vive LEAP"
  generic_name :Lighting

  # Requires TLS negotiation (max 10 connections)
  tcp_port 8081

  default_settings({
    username: "user",
    password: "pass",
  })

  def on_load
    transport.tokenizer = Tokenizer.new do |io|
      length, unpaired = 0, 0
      loop do
        case io.read_char
        when '{' then unpaired += 1
        when '}' then unpaired -= 1
        when Nil then break
        end

        length += 1
        break if unpaired.zero?
      end
      unpaired.zero? && length > 0 ? length : -1
    end

    on_update
  end

  @username : String = ""
  @password : String = ""

  # area_id => presence, update time
  @sensors : Hash(String, Tuple(Bool, Int64)) = {} of String => Tuple(Bool, Int64)

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
  end

  def disconnected
    @sensors.clear
    schedule.clear
  end

  def connected
    # this request needs to be made before anything else to negotiate protocol version
    request = Request.new("/clientsetting", :update_request, {
      ClientSetting: {
        ClientMajorVersion: 1,
      },
    })
    send request.to_json, priority: 99, name: request.name?

    schedule.every(1.minute) { ping }
  end

  # This is called after the protocol version is negotiated
  protected def authenticate
    request = Request.new("/login", :update_request, {
      Login: {
        ContextType: "Application",
        LoginId:     @username,
        Password:    @password,
      },
    })
    send request.to_json, priority: 99, name: request.name?
  end

  def ping
    request = Request.new("/server/status/ping")
    send request.to_json, priority: 0, name: request.name?
  end

  # gets the status of all areas
  def area_status?
    request = Request.new("/area/status")
    send request.to_json, name: request.name?
  end

  protected def subscribe_areas
    request = Request.new("/area/status", :subscribe_request)
    send request.to_json, name: :subscribe_area_status
  end

  # get the status of all zones
  def zone_status?
    request = Request.new("/zone/status")
    send request.to_json, name: request.name?
  end

  protected def subscribe_zones
    request = Request.new("/zone/status", :subscribe_request)
    send request.to_json, name: :subscribe_zone_status
  end

  def zone_level(zone_id : String | Int32, level : Float64)
    request = Request.new("/zone/#{zone_id}/commandprocessor", :create_request, {
      Command: {
        CommandType:           "GoToDimmedLevel",
        DimmedLevelParameters: {
          Level: level,
        },
      },
    })
    send request.to_json, name: request.name?
  end

  def zone_lighting(zone_id : String | Int32, state : Bool)
    request = Request.new("/zone/#{zone_id}/commandprocessor", :create_request, {
      Command: {
        CommandType:             "GoToSwitchedLevel",
        SwitchedLevelParameters: {
          SwitchedLevel: state ? "On" : "Off",
        },
      },
    })
    send request.to_json, name: request.name?
  end

  def zone_contact_closure(zone_id : String | Int32, state : Bool)
    request = Request.new("/zone/#{zone_id}/commandprocessor", :create_request, {
      Command: {
        CommandType:        "GoToCCOLevel",
        CCOLevelParameters: {
          CCOLevel: state ? "Closed" : "Open",
        },
      },
    })
    send request.to_json, name: request.name?
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Lutron sent: #{data}" }
    request = Request.from_json(data)

    url = request["Url"]?
    status = request["StatusCode"]? || "200 OK"
    message_type = request["MessageBodyType"]?

    # process the message based on its type by preference
    case message_type
    when "OneClientSettingDefinition"
      setting = ClientSetting.from_json request.body
      logger.debug { "protocol version negotiated #{setting.protocol.version}, authenticating" }
      authenticate
    when "MultipleAreaStatus"
      statuses = MultipleAreaStatus.from_json request.body
      timestamp = Time.utc.to_unix

      statuses.states.each do |status|
        base_key = status.status_key
        self["#{base_key}_level"] = status.level if status.level

        if status.occupancy
          self["#{base_key}_occupied"] = status.occupancy
          @sensors[base_key] = {status.occupancy.try(&.occupied?) || false, timestamp}
        end
      end
    when "MultipleZoneStatus"
      statuses = MultipleZoneStatus.from_json request.body
      statuses.states.each { |status| set_zone(status) }
    when "OneZoneStatus"
      set_zone(OneZoneStatus.from_json(request.body).status)
    when "ExceptionDetail"
      # get status code
      code, status = status.split(" ", 2)
      details = ExceptionDetail.from_json request.body
      error_message = "operation #{url} failed with #{code}: #{status}, #{details.message} [#{details.error_code}]"
      logger.warn { error_message }
      if task && task.name == url
        task.abort error_message
      else
        # ignore the current task
        return
      end
    when nil
      case url
      when "/server/status/ping"
        logger.debug { "got ping response" }
      end
    else
      logger.debug { "unknown message type #{message_type}" }
    end

    task.try &.success
  end

  protected def set_zone(status)
    base_key = status.status_key
    self["#{base_key}"] = status.switched_level.try(&.on?) if status.switched_level
    self["#{base_key}_level"] = status.level if status.level
    self["#{base_key}_availability"] = status.availability if status.availability
    self["#{base_key}_contact_closure"] = status.contact_closure if status.contact_closure
  end

  # ======================
  # Sensor interface
  # ======================

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if type && type != "Presence"
    return NO_MATCH if mac && mac != config.ip

    @sensors.map do |area_id, (presence, timestamp)|
      Interface::Sensor::Detail.new(
        type: SensorType::Presence,
        value: presence ? 1.0 : 0.0,
        last_seen: timestamp,
        mac: config.ip.not_nil!,
        id: area_id,
        name: "#{system.name} #{area_id} occupancy",
        module_id: module_id,
        binding: "#{area_id}_occupied"
      )
    end
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless mac == config.ip
    return nil unless id

    sensor_found = @sensors[id]?
    return nil unless sensor_found
    presence, timestamp = sensor_found

    Interface::Sensor::Detail.new(
      type: SensorType::Presence,
      value: presence ? 1.0 : 0.0,
      last_seen: timestamp,
      mac: mac,
      id: id,
      name: "#{system.name} #{id} occupancy",
      module_id: module_id,
      binding: "#{id}_occupied"
    )
  end
end
