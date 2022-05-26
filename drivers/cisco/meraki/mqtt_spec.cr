require "spec"
require "mqtt"

DriverSpecs.mock_driver "Place::MQTT" do
  # ============================
  # CONNECTION
  # ============================
  puts "===== CONNECTION NEGOTIATION ====="
  connect = MQTT::V3::Connect.new
  connect.id = MQTT::RequestType::Connect
  connect.keep_alive_seconds = 60_u16
  connect.client_id = "placeos"
  connect.clean_start = true
  connect.username = "user"
  connect.password = "pass"
  connect.packet_length = connect.calculate_length
  should_send(connect.to_slice)

  connack = MQTT::V3::Connack.new
  connack.id = MQTT::RequestType::Connack
  connack.packet_length = connack.calculate_length
  responds(connack.to_slice)

  # ============================
  # SUBSCRIPTIONS
  # ============================
  puts "===== CHECKING DESKS SUBSCRIPTION ====="
  packet = MQTT::V3::Subscribe.new
  packet.id = MQTT::RequestType::Subscribe
  packet.qos = MQTT::QoS::BrokerReceived
  packet.message_id = 2_u16
  packet.topic = "/merakimv/+/net.meraki.detector"
  packet.packet_length = packet.calculate_length
  should_send(packet.to_slice)

  suback = MQTT::V3::Suback.new
  suback.id = MQTT::RequestType::Suback
  suback.message_id = 2_u16
  suback.return_codes = [MQTT::QoS::FireAndForget]
  suback.packet_length = suback.calculate_length
  responds(suback.to_slice)

  puts "===== CHECKING LUX SUBSCRIPTION ====="
  packet = MQTT::V3::Subscribe.new
  packet.id = MQTT::RequestType::Subscribe
  packet.qos = MQTT::QoS::BrokerReceived
  packet.message_id = 4_u16
  packet.topic = "/merakimv/+/light"
  packet.packet_length = packet.calculate_length
  should_send(packet.to_slice)

  suback = MQTT::V3::Suback.new
  suback.id = MQTT::RequestType::Suback
  suback.message_id = 4_u16
  suback.return_codes = [MQTT::QoS::FireAndForget]
  suback.packet_length = suback.calculate_length
  responds(suback.to_slice)

  puts "===== CHECKING COUNTS SUBSCRIPTION ====="
  packet = MQTT::V3::Subscribe.new
  packet.id = MQTT::RequestType::Subscribe
  packet.qos = MQTT::QoS::BrokerReceived
  packet.message_id = 6_u16
  packet.topic = "/merakimv/+/0"
  packet.packet_length = packet.calculate_length
  should_send(packet.to_slice)

  suback = MQTT::V3::Suback.new
  suback.id = MQTT::RequestType::Suback
  suback.message_id = 6_u16
  suback.return_codes = [MQTT::QoS::FireAndForget]
  suback.packet_length = suback.calculate_length
  responds(suback.to_slice)

  # ============================
  # REMOTE PUBLISH
  # ============================
  puts "===== REMOTE PUBLISH ====="
  publish = MQTT::V3::Publish.new
  publish.id = MQTT::RequestType::Publish
  publish.message_id = 8_u16
  publish.topic = "/merakimv/1234/light"
  publish.payload = %({"lux":33.2,"ts":1642564552})
  publish.packet_length = publish.calculate_length

  transmit publish.to_slice
  sleep 0.1 # wait a bit for processing
  status["camera_1234_lux"].should eq(33.2)

  # ============================
  # CHECK SENSOR INTERFACE
  # ============================
  lux_sensor = {
    "status"    => "normal",
    "type"      => "illuminance",
    "value"     => 33.2,
    "last_seen" => 1642564552,
    "mac"       => "1234",
    "id"        => "lux",
    "name"      => "Meraki Camera 1234: lux",
    "module_id" => "spec_runner",
    "binding"   => "camera_1234_lux",
    "unit"      => "lx",
    "location"  => "sensor",
  }
  exec(:sensors).get.should eq([lux_sensor])
  exec(:sensor, "1234", "lux").get.should eq(lux_sensor)

  # ============================
  # CHECK LOCATABLE INTERFACE
  # ============================
  puts "===== CHECKING LOCATABLE INTERFACE ====="
  publish = MQTT::V3::Publish.new
  publish.id = MQTT::RequestType::Publish
  publish.message_id = 8_u16
  publish.topic = "/merakimv/camera_serial/net.meraki.detector"
  publish.payload = %({
    "_v": 2,
    "time": "2022-01-20 02:14:00",
    "coords":[],
    "desks": [
      [185, 282, 227, 211, 272, 158, 0],
      [376, 197, 321, 268, 264, 365, 0],
      [401, 450, 460, 355, 499, 273, 0],
      [572, 348, 547, 414, 506, 483, 0],
      [312, 571, 259, 546, 210, 515, 0],
      [536, 492, 494, 529, 446, 560, 0],
      [137, 542, 162, 573, 189, 597, 0]
    ]
  })
  publish.packet_length = publish.calculate_length

  transmit publish.to_slice
  sleep 0.1 # wait a bit for processing
  status["camera_1234_lux"].should eq(33.2)

  exec(:device_locations, "zone-456").get.should eq([{
    "location"    => "desk",
    "at_location" => 0,
    "map_id"      => "desk-1234",
    "level"       => "zone-123",
    "building"    => "zone-456",
    "capacity"    => 1,
    "area_lux"    => nil,
    "merakimv"    => "camera_serial",
  }])
end
