require "placeos-driver/spec"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxRx" do
  # Connected callback makes some queries
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Receiver"}}})

  should_send "/Device/XioSubscription/Subscriptions"
  responds %({"Device": {"XioSubscription": {"Subscriptions": {
    "00000000-0000-4002-0054-018a0089fd1c": {
      "Address": "https://10.254.47.133/onvif/services",
      "AudioChannels": 0,
      "AudioFormat": "No Audio",
      "Bitrate": 750,
      "Encryption": true,
      "Fps": 0,
      "MulticastAddress": "228.228.228.224",
      "Position": 2,
      "Resolution": "0x0",
      "RtspUri": "rtsp://10.254.47.133:554/live.sdp",
      "SessionName": "DM-NVX-E30-DEADBEEF1234",
      "SnapshotUrl": "",
      "Transport": "TS/RTP",
      "UniqueId": "00000000-0000-4002-0054-018a0089fd1c",
      "VideoFormat": "Pixel",
      "IsSyncDetected": false,
      "Status": "SUBSCRIBED"
    }
  }}}})

  should_send "/Device/Localization/Name"
  responds %({"Device": {"Localization": {"Name": "projector"}}})

  should_send "/Device/Osd/Text"
  responds %({"Device": {"Osd": {"Text": "Hearing Loop"}}})

  should_send "/Device/DeviceSpecific/ActiveVideoSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveVideoSource": "Stream"}}})

  should_send "/Device/AvRouting/Routes"
  responds %({"Device": {"AvRouting": {"Routes": [
    {
      "Name": "Routing0",
      "AudioSource": "00000000-0000-4002-0054-018a0089fd1c",
      "VideoSource": "00000000-0000-4002-0054-018a0089fd1c",
      "UsbSource": "00000000-0000-4002-0054-018a0089fd1c",
      "AutomaticStreamRoutingEnabled": false,
      "UniqueId": "cc063ec3-d135-4413-9ee9-5a9264b5642c"
    }
  ]}}})

  should_send "/Device/DeviceSpecific/ActiveAudioSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveAudioSource": "Input1"}}})

  status[:video_source].should eq("Stream-00000000-0000-4002-0054-018a0089fd1c")
  status[:audio_source].should eq("Input1")
  status[:device_name].should eq("projector")
  status[:osd_text].should eq("Hearing Loop")

  # we call this manually as the driver isn't loaded in websocket mode
  exec :authenticate

  # We expect the first thing it to do is authenticate
  auth = URI::Params.build { |form|
    form.add("login", "admin")
    form.add("passwd", "admin")
  }

  expect_http_request do |request, response|
    io = request.body
    if io
      request_body = io.gets_to_end
      if request_body == auth
        response.status_code = 200
        response.headers["CREST-XSRF-TOKEN"] = "1234"
        cookies = response.cookies
        cookies["AuthByPasswd"] = "true"
        cookies["iv"] = "true"
        cookies["tag"] = "true"
        cookies["userid"] = "admin"
        cookies["userstr"] = "admin"
      else
        response.status_code = 401
      end
    else
      raise "expected request to include login form #{request.inspect}"
    end
  end
end
