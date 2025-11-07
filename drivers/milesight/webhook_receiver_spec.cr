require "placeos-driver/spec"

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
end
