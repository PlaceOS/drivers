require "placeos-driver/spec"
require "http/server"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxRx" do
  # The driver authenticates over HTTP, then queries device state from
  # `on_authenticated` over the websocket. The driver isn't loaded in websocket
  # mode in specs, so we kick off authentication manually.
  exec :authenticate

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

  # on_authenticated now runs and queries device state. These are dispatched
  # through the priority queue, so higher-priority (default 50) status queries
  # are sent ahead of the source queries (priority 0).
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Receiver"}}})

  # NOTE: the device sends compact single-line JSON. The driver's response
  # parser walks the frame line-by-line, so responses must not be pretty-printed
  # across multiple lines or they will never match.
  should_send "/Device/XioSubscription/Subscriptions"
  responds %({"Device":{"XioSubscription":{"Subscriptions":{"00000000-0000-4002-0054-018a0089fd1c":{"Address":"https://10.254.47.133/onvif/services","AudioChannels":0,"AudioFormat":"No Audio","Bitrate":750,"Encryption":true,"Fps":0,"MulticastAddress":"228.228.228.224","Position":2,"Resolution":"0x0","RtspUri":"rtsp://10.254.47.133:554/live.sdp","SessionName":"DM-NVX-E30-DEADBEEF1234","SnapshotUrl":"","Transport":"TS/RTP","UniqueId":"00000000-0000-4002-0054-018a0089fd1c","VideoFormat":"Pixel","IsSyncDetected":false,"Status":"SUBSCRIBED"}}}}})

  should_send "/Device/Localization/Name"
  responds %({"Device": {"Localization": {"Name": "projector"}}})

  should_send "/Device/Osd/Text"
  responds %({"Device": {"Osd": {"Text": "Hearing Loop"}}})

  should_send "/Device/AvioV2/Inputs"
  responds %({"Device": {"AvioV2": {"Inputs": {}}}})

  should_send "/Device/DeviceSpecific/ActiveVideoSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveVideoSource": "Stream"}}})

  should_send "/Device/AvRouting/Routes"
  responds %({"Device":{"AvRouting":{"Routes":[{"Name":"Routing0","AudioSource":"00000000-0000-4002-0054-018a0089fd1c","VideoSource":"00000000-0000-4002-0054-018a0089fd1c","UsbSource":"00000000-0000-4002-0054-018a0089fd1c","AutomaticStreamRoutingEnabled":false,"UniqueId":"cc063ec3-d135-4413-9ee9-5a9264b5642c"}]}}})

  should_send "/Device/DeviceSpecific/ActiveAudioSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveAudioSource": "Input1"}}})

  status[:video_source].should eq("Stream-00000000-0000-4002-0054-018a0089fd1c")
  status[:audio_source].should eq("Input1")
  status[:device_name].should eq("projector")
  status[:osd_text].should eq("Hearing Loop")

  # ------------------------------------------------------------------
  # background image: download -> multipart upload -> websocket set
  # ------------------------------------------------------------------

  # Serve the source image from a local HTTP server so the driver can download
  # it (this stands in for the remote image host). It returns a generic
  # `application/octet-stream` like the PlaceOS uploads endpoint, so we can prove
  # the upload uses the filename-derived `image/*` type instead.
  image_payload = "JPEG-IMAGE-DATA"
  image_server = HTTP::Server.new do |context|
    context.response.content_type = "application/octet-stream"
    context.response.print image_payload
  end
  image_addr = image_server.bind_unused_port
  spawn { image_server.listen }
  Fiber.yield

  image_url = "http://127.0.0.1:#{image_addr.port}/i.jpg"

  begin
    exec(:set_background_image, image_url)

    # The driver downloads the image then uploads it to the device as a
    # multipart/form-data POST.
    expect_http_request do |request, response|
      request.method.should eq("POST")
      request.path.should eq("/Device")
      content_type = request.headers["Content-Type"]? || ""
      content_type.should start_with("multipart/form-data")
      # the NVX parser requires an unquoted boundary parameter
      content_type.should contain("boundary=")
      content_type.should_not contain(%(boundary="))
      request.headers["CREST-XSRF-TOKEN"]?.should eq("1234")

      body = request.body.try(&.gets_to_end) || ""
      body.should contain(%(name="UploadFilePath"))
      body.should contain("/data/web/tmp/Images/Local/")
      body.should contain(%("Image01"))
      body.should contain(%("UploadFile":"i.jpg"))
      body.should contain(%(filename="i.jpg"))
      # filename-derived content type wins over the generic download header
      body.should contain("image/jpeg")
      body.should_not contain("application/octet-stream")
      body.should contain(image_payload)

      response.status_code = 200
      response.print %({"Actions":[{"Operation":"SetPartial","Results":[{"Path":"Device.ImageMgmnt.LocalImages.Image01","Property":"UploadFile","StatusId":9,"StatusInfo":"i.jpg:Success"}],"TargetObject":"ImageMgmnt","Version":"2.1.0"}]})
    end

    # Then it points the output at the freshly uploaded local image.
    should_send %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Local"}}}}})
    responds %({"Actions":[{"Results":[{"StatusId":9}]}]})

    should_send %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"Local":{"ImageName":"i.jpg"}}}}}})
    responds %({"Actions":[{"Results":[{"StatusId":9}]}]})
  ensure
    image_server.close
  end
end
