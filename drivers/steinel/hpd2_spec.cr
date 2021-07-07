require "placeos-driver/spec"

DriverSpecs.mock_driver "Xovis::SensorAPI" do
  # Send the request
  retval = exec(:get_status)
  data = %({"AppVersion": "3.2.3", "FpgaVersion": "v300", "KnxSapNumber": "0", "KnxVersion": "0", "KnxAddr":
  "", "GitRevision": "d45734c2", "ModelName": "15_2xroute_fix26", "FrameProcessingTimeMs": 1179,
  "AverageFps5": 0.850314, "AverageFps50": 0.855873, "RunningTimeHHMMSS": "672:55:58",
  "UptimeHHMMSS": "672:56:35", "IrLedOn": 0, "DetectedPersons": 0, "PersonPresence": 0,
  "DetectedPersonsZone": [0, 0, 0, 0, 0], "PersonPresenceZone": [0, 0, 0, 0, 0],
  "DetectionZonesPresent": 0, "GlobalIlluminanceLux": 39.0, "LuxZone": [0.0, 0.0, 0.0, 0.0, 0.0],
  "GlobalLightValue": 72, "ArmsensorCpuUsage": "20", "WebServerCpuUsage": "2", "Temperature":
  "27.745661", "Humidity": "25.286158", "KnxDetected": "0", "KnxProgramMode": "0", "KnxLedState":
  "0", "final": "OK" })

  # We should request a new token from Floorsense
  expect_http_request do |request, response|
    if request.headers["Authorization"]? == "Basic YWRtaW46c3RlaW5lbA=="
      response.status_code = 200
      response.output.puts data
    else
      puts request.headers.inspect
      response.status_code = 401
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq(JSON.parse(data))
end
