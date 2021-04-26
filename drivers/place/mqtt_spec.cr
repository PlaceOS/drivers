require "mqtt"

DriverSpecs.mock_driver "Place::Pinger" do
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
  # SUBSCRIPTION
  # ============================
  puts "===== SUBSCRIPTION REQUESTED ====="
  packet = MQTT::V3::Subscribe.new
  packet.id = MQTT::RequestType::Subscribe
  packet.qos = MQTT::QoS::BrokerReceived
  packet.message_id = 2_u16
  packet.topic = "root/#"
  packet.packet_length = packet.calculate_length
  should_send(packet.to_slice)

  suback = MQTT::V3::Suback.new
  suback.id = MQTT::RequestType::Suback
  suback.message_id = 2_u16
  suback.return_codes = [MQTT::QoS::FireAndForget]
  suback.packet_length = suback.calculate_length
  responds(suback.to_slice)

  # ============================
  # REMOTE PUBLISH
  # ============================
  puts "===== REMOTE PUBLISH ====="
  publish = MQTT::V3::Publish.new
  publish.id = MQTT::RequestType::Publish
  publish.message_id = 3_u16
  publish.topic = "root/topic"
  publish.payload = "testing"
  publish.packet_length = publish.calculate_length

  transmit publish.to_slice
  sleep 0.1 # wait a bit for processing
  status["root/topic"].should eq("testing")

  # ============================
  # DRIVER PUBLISH
  # ============================
  puts "===== DRIVER PUBLISH ====="
  exec(:publish, "root/topic/action", "value")

  publish = MQTT::V3::Publish.new
  publish.id = MQTT::RequestType::Publish
  publish.message_id = 3_u16
  publish.topic = "root/topic/action"
  publish.payload = "value"
  publish.packet_length = publish.calculate_length
  should_send(publish.to_slice)
end
