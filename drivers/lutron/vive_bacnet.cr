require "placeos-driver"
require "placeos-driver/interface/sensor"

# Documentation: https://aca.im/driver_docs/Lutron/BACnet-PIC-Statementfor-VIVE.pdf

class Lutron::ViveBacnet < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Lutron Vive BACnet"
  generic_name :Lighting

  default_settings({
    device_id: 389999,
  })

  accessor bacnet : BACnet_1

  @device_id : UInt32 = 0_u32
  @last_updated : Int64 = 0_i64
  @occupancy : Bool? = nil

  def on_load
    on_update
  end

  def on_update
    @device_id = setting(UInt32, :device_id)
    subscriptions.clear

    # Light level
    system.subscribe(:BACnet, 1, "#{@device_id}.AnalogValue[2]") { |_sub, value| self[:lighting_level] = value.to_f }

    # Total Power (in watts)
    system.subscribe(:BACnet, 1, "#{@device_id}.AnalogValue[18]") { |_sub, value| self[:power_usage] = value.to_f }

    # lighting on / off
    system.subscribe(:BACnet, 1, "#{@device_id}.BinaryValue[3]") { |_sub, value| self[:lighting] = value == "1" }

    # occupancy disabled
    system.subscribe(:BACnet, 1, "#{@device_id}.BinaryValue[7]") { |_sub, value| self[:occupancy_disabled] = value == "1" }

    # occupancy state
    system.subscribe(:BACnet, 1, "#{@device_id}.MultiStateValue[8]") do |_sub, value|
      @occupancy = case value
                   when "1"
                     false
                   when "2"
                     true
                   else
                     nil
                   end
      self[:occupancy] = @occupancy
      self[:occupancy_sensor] = @occupancy.nil? ? nil : (@occupancy ? 1.0 : 0.0)
      @last_updated = Time.utc.to_unix
    end

    schedule.clear
    schedule.every((4 + rand(3)).seconds) do
      bacnet.update_value(@device_id, 2, "AnalogValue").get
      bacnet.update_value(@device_id, 3, "BinaryValue").get
      bacnet.update_value(@device_id, 8, "MultiStateValue").get
    end
  end

  def level(percentage : Float32)
    percentage = 0.0_f32 if percentage < 0.0_f32
    percentage = 100.0_f32 if percentage > 100.0_f32
    bacnet.write_real(@device_id, 2, percentage).get
    self[:lighting_level] = percentage
  end

  def lighting(state : Bool)
    bacnet.write_binary(@device_id, 3, state).get
    self[:lighting] = state
  end

  def disable_occupancy(state : Bool)
    bacnet.write_binary(@device_id, 7, state).get
    self[:occupancy_disabled] = state
  end

  # ======================
  # Sensor interface
  # ======================

  NO_MATCH = [] of Interface::Sensor::Detail

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    logger.debug { "sensors of type: #{type}, mac: #{mac}, zone_id: #{zone_id} requested" }

    return NO_MATCH if type && type != "Presence"
    return NO_MATCH if mac && mac != @device_id.to_s
    return NO_MATCH if zone_id && !system.zones.includes?(zone_id)

    [
      Interface::Sensor::Detail.new(
        type: SensorType::Presence,
        value: @occupancy ? 1.0 : 0.0,
        last_seen: @last_updated,
        mac: @device_id.to_s,
        id: "occupancy",
        name: "#{system.name}: occupancy",
        module_id: module_id,
        binding: "occupancy_sensor"
      ),
    ]
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    logger.debug { "sensor mac: #{mac}, id: #{id} requested" }
    return nil unless id == "occupancy"
    return nil unless mac == @device_id.to_s
    return nil if @last_updated == 0_i64

    Interface::Sensor::Detail.new(
      type: SensorType::Presence,
      value: @occupancy ? 1.0 : 0.0,
      last_seen: @last_updated,
      mac: @device_id.to_s,
      id: "occupancy",
      name: "#{system.name}: occupancy",
      module_id: module_id,
      binding: "occupancy_sensor"
    )
  end
end
