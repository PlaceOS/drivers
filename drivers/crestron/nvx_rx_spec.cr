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
  source_requests = [] of String
  image_server = HTTP::Server.new do |context|
    source_requests << context.request.resource
    context.response.content_type = "application/octet-stream"
    context.response.print image_payload
  end
  image_addr = image_server.bind_unused_port
  spawn { image_server.listen }
  Fiber.yield

  source_resource = "/i.jpg?asset=fixture"
  image_url = "http://127.0.0.1:#{image_addr.port}#{source_resource}"
  storage_query = "/Device/ImageMgmnt"
  output_query = "/Device/BackgroundImage/Outputs/Output1"
  pending_image = %({"Device":{"ImageMgmnt":{"Version":"2.1.0","LocalImages":{"Image01":{"UploadFile":"i.jpg","UploadStatus":"Pending","PreviewImage":""}}}}})
  uploaded_image = %({"Device":{"ImageMgmnt":{"Version":"2.1.0","LocalImages":{"Image01":{"Name":"i.jpg","UploadStatus":"Success","PreviewImage":"/preview/Images/Local/i.jpg"}}}}})
  stored_image = %({"Device":{"ImageMgmnt":{"Version":"2.1.0","LocalImages":{"Image01":{"Name":"i.jpg","UploadStatus":"Ready","PreviewImage":"/preview/Images/Local/i.jpg"}}}}})
  remote_output = %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Remote","StatusCode":0,"StatusMessage":"NA","Local":{"ImageName":"","PreviewImage":""}}}}}})
  local_output = %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Local","StatusCode":0,"StatusMessage":"Ready","Local":{"ImageName":"i.jpg","PreviewImage":"/preview/Images/Local/i.jpg"}}}}}})
  upload_ack = %({"Actions":[{"Operation":"SetPartial","Results":[{"Path":"Device.ImageMgmnt.LocalImages.Image01","Property":"UploadFilePath","StatusId":9,"StatusInfo":"File Upload Operation Succeeded"},{"Path":"Device.ImageMgmnt.LocalImages.Image01","Property":"UploadFile","StatusId":9,"StatusInfo":"i.jpg:Success"}],"TargetObject":"ImageMgmnt","Version":"2.1.0"}]})
  aggregate_upload_ack = %({"Actions":[{"Operation":"SetPartial","Results":[{"Path":"Device.ImageMgmnt","StatusId":0,"StatusInfo":"OK"}],"TargetObject":"ImageMgmnt","Version":"2.1.0"}]})
  name_ack = %({"Actions":[{"TargetObject":"BackgroundImage","Results":[{"Path":"Device.BackgroundImage.Outputs.Output1.Local","Property":"ImageName","StatusId":0,"StatusInfo":"OK"}]}]})
  mode_ack = %({"Actions":[{"TargetObject":"BackgroundImage","Results":[{"Path":"Device.BackgroundImage.Outputs.Output1","Property":"HostBackgroundImage","StatusId":0,"StatusInfo":"OK"}]}]})
  set_image_name = %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"Local":{"ImageName":"i.jpg"}}}}}})
  set_image_mode = %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Local"}}}}})
  upload_filenames = [] of String
  local_filename = ->(body : String) do
    filename = /filename="([^"]+)"/.match(body).not_nil![1]
    filename.should_not eq "i.jpg"
    File.extname(filename).should eq ".jpg"
    upload_filenames.should_not contain(filename)
    upload_filenames << filename
    body.should contain(%("UploadFile":"#{filename}"))
    filename
  end

  begin
    upload = exec(:set_background_image, image_url)
    first_filename = ""

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
      first_filename = local_filename.call(body)
      # filename-derived content type wins over the generic download header
      body.should contain("image/jpeg")
      body.should_not contain("application/octet-stream")
      body.should contain(image_payload)

      response.status_code = 200
      response.print upload_ack.gsub("i.jpg", first_filename)
    end

    # Upload acceptance precedes conversion and selection.
    should_send storage_query
    pending_at = Time.instant
    responds pending_image.gsub("i.jpg", first_filename)
    should_send storage_query, 7.seconds
    (Time.instant - pending_at).should be >= 4.9.seconds
    responds uploaded_image.gsub("i.jpg", first_filename)
    should_send storage_query, 7.seconds
    responds stored_image.gsub("i.jpg", first_filename)
    should_send output_query
    responds %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Local"}}}}}\n\n#{remote_output})

    should_send set_image_name.gsub("i.jpg", first_filename)
    responds name_ack
    should_send set_image_mode
    responds mode_ack
    should_send output_query
    responds local_output.gsub("i.jpg", first_filename)
    upload.get.raw.should be_nil
    source_requests.should eq [source_resource]

    # The longer readiness sequence overlaps the initial device discovery.
    expect_http_request(2.seconds) do |request, response|
      request.method.should eq("GET")
      request.path.should eq("/Device/DeviceInfo")
      response.print %({"Device":{"DeviceInfo":{"Model":"DM-NVX-363","Category":"DM","Version":"2.1.0","DeviceVersion":"7.1.5259.00090","PufVersion":"7.1.5259.00090","BuildDate":"Jul 16 2025","MacAddress":"00:00:00:00:00:01","SerialNumber":"fixture","Name":"projector"}}})
    end

    # Reconciliation checks both the selected output and the stored image.
    readiness = exec(:background_image_ready?)
    should_send output_query
    responds local_output.gsub("i.jpg", first_filename)
    should_send storage_query
    responds stored_image.gsub("i.jpg", first_filename)
    readiness.get.as_bool.should be_true

    readiness = exec(:background_image_ready?)
    should_send output_query
    responds local_output.gsub("i.jpg", first_filename)
    should_send storage_query
    responds %({"Device":{"ImageMgmnt":{"Version":"2.1.0","LocalImages":{"Image01":{"Name":"#{first_filename}","PreviewImage":""}}}}})
    readiness.get.as_bool.should be_false

    readiness = exec(:background_image_ready?)
    should_send output_query
    responds remote_output
    readiness.get.as_bool.should be_false

    # An uncertain upload is retried from the same URL under a fresh filename.
    first_request = source_requests.size
    recovered_upload = exec(:set_background_image, image_url)
    expect_http_request do |request, response|
      local_filename.call(request.body.not_nil!.gets_to_end)
      response.status_code = 503
    end
    upload_retry_name = ""
    expect_http_request do |request, response|
      body = request.body.not_nil!.gets_to_end
      upload_retry_name = local_filename.call(body)
      body.should contain(image_payload)
      response.status_code = 200
      response.print aggregate_upload_ack
    end
    # An aggregate acknowledgement is provisional. The previous Ready file
    # and a matching Pending file cannot confirm the new upload.
    should_send storage_query
    responds stored_image.gsub("i.jpg", first_filename)
    should_send storage_query, 7.seconds
    responds pending_image.gsub("i.jpg", upload_retry_name)
    should_send storage_query, 7.seconds
    responds stored_image.gsub("i.jpg", upload_retry_name)
    should_send output_query
    responds local_output.gsub("i.jpg", first_filename)
    should_send set_image_name.gsub("i.jpg", upload_retry_name)
    responds name_ack
    should_send output_query
    responds local_output.gsub("i.jpg", upload_retry_name)
    recovered_upload.get.raw.should be_nil
    source_requests[first_request..].should eq [source_resource, source_resource]

    # Two HTTP 200 responses with fully qualified NVX rejections exhaust the
    # retry before querying storage or changing the selected image.
    rejected = exec(:set_background_image, image_url)
    2.times do
      expect_http_request do |request, response|
        request.method.should eq("POST")
        local_filename.call(request.body.not_nil!.gets_to_end)
        response.status_code = 200
        response.print %({"Actions":[{"TargetObject":"ImageMgmnt","Results":[{"Path":"Device.ImageMgmnt.LocalImages.Image01.UploadFile","StatusId":3,"StatusInfo":"Unsupported property"}]}]})
      end
    end
    expect_raises(PlaceOS::Driver::RemoteException, /device rejected upload background image .*\.jpg: Unsupported property/) { rejected.get }

    invalid = exec(:set_background_image, image_url)
    2.times do
      filename = ""
      expect_http_request do |request, response|
        request.method.should eq("POST")
        filename = local_filename.call(request.body.not_nil!.gets_to_end)
        response.status_code = 200
        response.print aggregate_upload_ack
      end
      should_send storage_query
      responds %({"Device":{"ImageMgmnt":{"Version":"2.1.0","LocalImages":{"Image01":{"UploadFile":"#{filename}","UploadStatus":"InvalidFile","DetailedMessage":"Unsupported Resolution"}}}}})
    end
    expect_raises(PlaceOS::Driver::RemoteException, /device could not store background image .*\.jpg: Unsupported Resolution/) { invalid.get }

    # A selection retry re-reads the output and keeps the already stored file.
    first_request = source_requests.size
    recovered_selection = exec(:set_background_image, image_url)
    selection_filename = ""
    expect_http_request do |request, response|
      request.method.should eq("POST")
      selection_filename = local_filename.call(request.body.not_nil!.gets_to_end)
      response.status_code = 200
      response.print upload_ack.gsub("i.jpg", selection_filename)
    end
    should_send storage_query
    responds stored_image.gsub("i.jpg", selection_filename)
    should_send output_query
    responds remote_output
    should_send set_image_name.gsub("i.jpg", selection_filename)
    responds name_ack
    should_send set_image_mode
    responds %({"Actions":[{"TargetObject":"BackgroundImage","Results":[{"Path":"Device.BackgroundImage.Outputs.Output1","Property":"HostBackgroundImage","StatusId":-4,"StatusInfo":"Generic error"}]}]})
    should_send output_query
    responds %({"Device":{"BackgroundImage":{"Outputs":{"Output1":{"HostBackgroundImage":"Remote","StatusCode":0,"StatusMessage":"NA","Local":{"ImageName":"#{selection_filename}","PreviewImage":"/preview/Images/Local/#{selection_filename}"}}}}}})
    should_send set_image_mode
    responds mode_ack
    should_send output_query
    responds local_output.gsub("i.jpg", selection_filename)
    recovered_selection.get.raw.should be_nil
    source_requests[first_request..].should eq [source_resource]
  ensure
    image_server.close
  end
end
