require "placeos-driver"
require "placeos-driver/interface/sensor"
require "bacnet"
require "jwt"

require "./p864_models"

class Optergy::P864 < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  generic_name :BMS
  descriptive_name "Optergy P864 BMS"
  uri_base "https://bms.org.com"

  default_settings({
    username: "admin",
    password: "password",

    # grab unit names from: https://github.com/spider-gazelle/crunits
    # Sensor type list: https://github.com/PlaceOS/driver/blob/master/src/placeos-driver/interface/sensor.cr#L8
    unit_mappings: {
      1 => {SensorType::Temperature, "Cel"},
    },
  })

  @username : String = ""
  @password : String = ""

  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  alias Mapping = Hash(Int32, Tuple(SensorType, String))
  @unit_mappings : Mapping = Mapping.new

  def on_load
    on_update

    schedule.every(1.minutes) { version }
    transport.before_request do |req|
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @unit_mappings = setting?(Mapping, :unit_mappings) || Mapping.new
  end

  def version
    response = get("/version", headers: auth_headers)
    NamedTuple(version: String).from_json(check response)[:version]
  end

  def configuration
    response = get("/api/device/config", headers: auth_headers)
    Config.from_json(check response)
  end

  TYPES = {"value", "input", "output"}

  {% begin %}
    {% for type in TYPES %}
      {% type_id = type.id %}
      {% url = "/api/a#{type.chars[0].id}/" %}

      def analog_{{ type.id }}s
        response = get({{url}}, headers: auth_headers)
        Array(AnalogValue).from_json(check response)
      end
    
      def analog_{{ type.id }}(instance : Int32)
        path = String.build do |str|
          str << {{url}}
          instance.to_s(str)
        end
        response = get(path, headers: auth_headers)
        AnalogValue.from_json(check response)
      end

      {% if type != "input" %}
        @[Security(Level::Administrator)]
        def write_analog_{{ type.id }}(instance : Int32, value : Float64, priority : Int32 = 8)
          path = String.build do |str|
            str << {{url}}
            instance.to_s(str)
          end
          response = post(path, headers: auth_headers, body: {
            value: value.to_s,
            arrayIndex: priority,
            property: "presentValue",
          }.to_json)
          AnalogValue.from_json(check response)
        end
      {% end %}
    {% end %}
  {% end %}

  {% begin %}
    {% for type in TYPES %}
      {% type_id = type.id %}
      {% url = "/api/b#{type.chars[0].id}/" %}

      def binary_{{ type.id }}s
        response = get({{url}}, headers: auth_headers)
        Array(BinaryValue).from_json(check response)
      end
    
      def binary_{{ type.id }}(instance : Int32)
        path = String.build do |str|
          str << {{url}}
          instance.to_s(str)
        end
        response = get(path, headers: auth_headers)
        BinaryValue.from_json(check response)
      end

      {% if type != "input" %}
        @[Security(Level::Administrator)]
        def write_binary_{{ type.id }}(instance : Int32, value : Bool, priority : Int32 = 8)
          path = String.build do |str|
            str << {{url}}
            instance.to_s(str)
          end
          response = post(path, headers: auth_headers, body: {
            value: value ? "Active" : "Inactive",
            arrayIndex: priority,
            property: "presentValue",
          }.to_json)
          BinaryValue.from_json(check response)
        end
      {% end %}
    {% end %}
  {% end %}

  @[Security(Level::Administrator)]
  def set_input_mode(instance : Int32, mode : String)
    response = post("/api/ai/#{instance}/mode", headers: auth_headers, body: {
      mode: mode,
    }.to_json)
    ModeResponse.from_json(check response)
  end

  # ==============
  # Authentication
  # ==============

  def token_expired?
    @auth_expiry < Time.utc
  end

  record TokenResponse, token : String do
    include JSON::Serializable
  end

  @[Security(Level::Administrator)]
  def get_token
    return @auth_token unless token_expired?

    response = post("/authorize", headers: HTTP::Headers{
      "Accept"       => "application/json",
      "Content-Type" => "application/json",
    }, body: {
      username: @username,
      password: @password,
    }.to_json)

    body = response.body
    now = Time.utc
    logger.debug { "received login response: #{body}" }

    if response.success?
      set_connected_state true
      token = TokenResponse.from_json(body).token
      payload, header = JWT.decode(token, verify: false, validate: false)

      # time is relative in this JWT (non standard)
      issued = payload["iat"].as_i64
      expires = payload["exp"].as_i64
      expires_at = now + (expires - issued - 3).seconds

      @auth_expiry = expires_at
      @auth_token = "Bearer #{token}"
    else
      set_connected_state false
      logger.error { "authentication failed with HTTP #{response.status_code}" }
      raise "failed to obtain access token"
    end
  end

  @[Security(Level::Administrator)]
  def auth_headers
    HTTP::Headers{
      "Accept"        => "application/json",
      "Content-Type"  => "application/json",
      "Authorization" => get_token,
    }
  end

  macro check(response)
    %resp =  {{response}}
    logger.debug { "received: #{%resp.body}" }
    raise "error response: #{%resp.status} (#{%resp.status_code})\n#{%resp.body}" unless %resp.success?
    %resp.body
  end

  # ======================
  # Sensor interface
  # ======================

  protected def to_sensor(object, mac, filter_type = nil) : Interface::Sensor::Detail?
    unit_number = object.units
    unit_lookup = unit_number ? BACnet::Unit.from_value(unit_number) : nil
    sensor_type = case unit_lookup
                  when Nil, .no_units?
                    if mapping = @unit_mappings[object.instance]?
                      unit = mapping[1]
                      mapping[0]
                    end
                  when .degrees_fahrenheit?, .degrees_celsius?, .degrees_kelvin?
                    SensorType::Temperature
                  when .percent_relative_humidity?
                    SensorType::Humidity
                  when .pounds_force_per_square_inch?
                    SensorType::Pressure
                  when .volts?, .millivolts?, .kilovolts?, .megavolts?
                    SensorType::Voltage
                  when .milliamperes?, .amperes?
                    SensorType::Current
                  when .millimeters_of_water?, .centimeters_of_water?, .inches_of_water?, .cubic_feet?, .cubic_meters?, .imperial_gallons?, .milliliters?, .liters?, .us_gallons?
                    SensorType::Volume
                  when .milliwatts?, .watts?, .kilowatts?, .megawatts?, .watt_hours?, .kilowatt_hours?, .megawatt_hours?
                    SensorType::Power
                  when .hertz?, .kilohertz?, .megahertz?
                    SensorType::Frequency
                  when .cubic_feet_per_second?, .cubic_feet_per_minute?, .cubic_feet_per_hour?, .cubic_meters_per_second?, .cubic_meters_per_minute?, .cubic_meters_per_hour?, .imperial_gallons_per_minute?, .milliliters_per_second?, .liters_per_second?, .liters_per_minute?, .liters_per_hour?, .us_gallons_per_minute?, .us_gallons_per_hour?
                    SensorType::Flow
                  when .percent?
                    SensorType::Level
                  end
    return nil unless sensor_type
    return nil if filter_type && sensor_type != filter_type

    unit = unit || case unit_lookup
    when Nil
    when .degrees_fahrenheit?           then "[degF]"
    when .degrees_celsius?              then "Cel"
    when .degrees_kelvin?               then "K"
    when .pounds_force_per_square_inch? then "[psi]"
    when .volts?                        then "V"
    when .millivolts?                   then "mV"
    when .kilovolts?                    then "kV"
    when .megavolts?                    then "MV"
    when .milliamperes?                 then "mA"
    when .amperes?                      then "A"
    when .cubic_feet?                   then "[cft_i]"
    when .cubic_meters?                 then "m3"
    when .imperial_gallons?             then "[gal_br]"
    when .milliliters?                  then "ml"
    when .liters?                       then "l"
    when .us_gallons?                   then "[gal_us]"
    when .milliwatts?                   then "mW"
    when .watts?                        then "W"
    when .kilowatts?                    then "kW"
    when .megawatts?                    then "MW"
    when .watt_hours?                   then "Wh"
    when .kilowatt_hours?               then "kWh"
    when .megawatt_hours?               then "MWh"
    when .hertz?                        then "Hz"
    when .kilohertz?                    then "kHz"
    when .megahertz?                    then "MHz"
    when .cubic_feet_per_second?        then "[cft_i]/s"
    when .cubic_feet_per_minute?        then "[cft_i]/min"
    when .cubic_feet_per_hour?          then "[cft_i]/h"
    when .cubic_meters_per_second?      then "m3/s"
    when .cubic_meters_per_minute?      then "m3/min"
    when .cubic_meters_per_hour?        then "m3/h"
    when .imperial_gallons_per_minute?  then "[gal_br]/min"
    when .milliliters_per_second?       then "ml/s"
    when .liters_per_second?            then "l/s"
    when .liters_per_minute?            then "l/min"
    when .liters_per_hour?              then "l/h"
    when .us_gallons_per_minute?        then "[gal_us]/min"
    when .us_gallons_per_hour?          then "[gal_us]/h"
    end

    value = object.value

    Interface::Sensor::Detail.new(
      type: sensor_type,
      value: value,
      last_seen: Time.utc.to_unix,
      mac: mac,
      id: object.instance.to_s,
      name: object.name,
      module_id: module_id,
      # binding: object_binding(device_id, object),
      unit: unit,
      status: object.out_of_service? ? Interface::Sensor::Status::OutOfService : Interface::Sensor::Status::Normal
    )
  end

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    this_mac = config.ip.as(String)
    return NO_MATCH if mac && mac != this_mac
    filter = type ? Interface::Sensor::SensorType.parse?(type) : nil
    analog_values.compact_map { |obj| to_sensor(obj, this_mac, filter) }
  rescue error
    logger.warn(exception: error) { "searching for sensors" }
    NO_MATCH
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }

    this_mac = config.ip.as(String)
    return nil if mac != this_mac
    return nil unless id
    instance = id.to_i?
    return nil unless instance

    device = (analog_value(instance) rescue nil)
    return nil unless device

    to_sensor(device, this_mac)
  end
end
