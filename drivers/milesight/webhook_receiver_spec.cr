require "placeos-driver/spec"
require "./cayenne_lpp_models"
require "./webhook_models"

DriverSpecs.mock_driver "Milesight::Webhook" do
  payload = %({
    "applicationID": "1",
    "applicationName": "PlaceOS",
    "deviceName": "vs321-test",
    "devEUI": "24e124443f171044",
    "rxInfo": [
      {
        "mac": "24e124fffef1ad25",
        "time": "2025-11-05T09:39:47.635887Z",
        "rssi": -64,
        "loRaSNR": 13.5,
        "name": "Local Gateway",
        "latitude": -37.78927,
        "longitude": 175.31519,
        "altitude": 65
      }
    ],
    "txInfo": {
      "frequency": 923400000,
      "dataRate": {
        "modulation": "LORA",
        "bandwidth": 125,
        "spreadFactor": 7
      },
      "adr": true,
      "codeRate": "4/5"
    },
    "fCnt": 937,
    "fPort": 85,
    "data": "Cu9wGwtpAXVjA2ftAAf/AQj0AgAEaGsF/QEA",
    "time": "2025-11-05T09:39:47.635887Z"
  })

  exec(:receive_webhook, "GET", {} of Nil => Nil, payload).get

  status["24e124443f171044.Temperature"]?.should eq 23.7

  exec(:sensors).get.as_a.size.should eq 4

  payload = Milesight::WebhookPayload.from_json "{\"applicationID\":\"1\",\"applicationName\":\"PlaceOS\",\"deviceName\":\"TC_4.15_VS351_Door_Counters\",\"devEUI\":\"24e124799f179505\",\"rxInfo\":[{\"mac\":\"24e124fffef1ad25\",\"time\":\"2025-11-30T22:09:57.737969Z\",\"rssi\":-88,\"loRaSNR\":13,\"name\":\"Local Gateway\",\"latitude\":-30.715,\"longitude\":15.313,\"altitude\":57}],\"txInfo\":{\"frequency\":923200000,\"dataRate\":{\"modulation\":\"LORA\",\"bandwidth\":125,\"spreadFactor\":7},\"adr\":true,\"codeRate\":\"4/5\"},\"fCnt\":1389,\"fPort\":85,\"data\":\"BcwAAAAAAXVj\",\"time\":\"2025-11-30T22:09:57.737969Z\"}"
  bytes = Base64.decode(payload.data)
  io = IO::Memory.new(bytes)
  puts io.read_bytes(Milesight::Frame).items.inspect
end
