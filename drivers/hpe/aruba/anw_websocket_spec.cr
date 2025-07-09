require "placeos-driver/spec"
require "base64"
require "./models"
require "./generated/**"

DriverSpecs.mock_driver "HPE::ANW::ArubaWebSocket" do
  settings({
    username:      "aruba",
    wss_key:       "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJEZW1vIFRva2VuIiwiaWF0IjoyMDI4MDMyNDY1LCJleHAiOjIwNTk1Njg0NjUsImF1ZCI6IiIsInN1YiI6ImxvY2F0aW9uIiwiQ3JlYXRlZCI6IjIwNTk1Njg1MTUifQ.0BXmeAtw_cMXzfvzLEE_o6-logmwlbjQxrxvYTqXUwQ",
    debug_payload: true,
  })

  should_send %(GET /streaming/api)
  sleep 1
  transmit get_stream

  retval = exec(:client_location, "00:1A:2B:3C:4D:5E")
  retval.get.should_not be_nil
end

def get_stream
  msg = HPE::ANW::StreamMessage::MsgProto.new(subject: "location", data: get_location, timestamp: Time.utc.to_unix,
    customer_id: "customer1")

  io = IO::Memory.new
  msg.to_protobuf(io)
  io.rewind
  io.to_slice
end

def get_location
  location = HPE::ANW::Location::StreamLocation.new(sta_location_x: 123.12, sta_location_y: 245.45,
    error_level: 23, unit: :feet, sta_eth_mac: HPE::ANW::Location::MacAddress.new(encode_mac("00:1A:2B:3C:4D:5E")),
    campus_id_string: "campus-2", building_id_string: "building-2", floor_id_string: "Level2",
    target_type: HPE::ANW::Location::TargetDevType::TARGET_TYPE_STATION, associated: false)

  io = IO::Memory.new
  location.to_protobuf(io)
  io.rewind
  io.to_slice
end

def encode_mac(mac : String) : Bytes
  bytes = mac.split(":").map { |part| part.to_u8(16) }
  slice = Slice(UInt8).new(bytes.size) { |i| bytes[i] }
  Base64.strict_encode(slice).to_slice
end
