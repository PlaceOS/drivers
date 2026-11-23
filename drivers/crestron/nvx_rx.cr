require "./cres_next"
require "placeos-driver/interface/switchable"
require "placeos-driver/interface/standby_image"
require "placeos-driver/stats"
require "uri"
require "mime"
require "openssl"
require "http/client"
require "http/formdata"
require "random/secure"

class Crestron::NvxRx < Crestron::CresNext # < PlaceOS::Driver
  alias Input = String
  alias Output = Int32
  include Interface::Switchable(Input, Output)
  include Interface::InputSelection(Input)
  include Interface::StandbyImage
  include Crestron::Receiver

  descriptive_name "Crestron NVX Receiver"
  generic_name :Decoder
  description <<-DESC
    Crestron NVX network media decoder
  DESC

  uri_base "wss://192.168.0.5/websockify"

  default_settings({
    username: "admin",
    password: "admin",

    # remove the underscore prefix to enable a scheduled reboot
    _reboot_cron:     "0 3 * * 0",
    _reboot_timezone: "Australia/Sydney",
  })

  @subscriptions : Hash(String, JSON::Any) = {} of String => JSON::Any
  @audio_follows_video : Bool = true

  MIN_SYNC_VERTICAL = 1080

  protected def on_authenticated : Nil
    audio_follows_video = setting?(Bool, :audio_follows_video)
    @audio_follows_video = audio_follows_video.nil? ? true : audio_follows_video

    # NVX hardware can be confiured a either a RX or TX unit - check this
    # device is in the correct mode
    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceSpecific.htm?Highlight=DeviceMode
    query("/DeviceSpecific/DeviceMode") do |mode|
      # "DeviceMode":"Transmitter|Receiver",
      next if mode == "Receiver"
      logger.warn { "device configured as a #{mode}" }
      self[:WARN] = "device configured as a #{mode}. Expecting Receiver"
    end

    # Get the registered subscriptions for index based switching.
    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/XioSubscription.htm?Highlight=XioSubscription
    query("/XioSubscription/Subscriptions") do |subs|
      self[:subscriptions] = @subscriptions = subs.as_h
    end

    # Refresh state now that we're authenticated. The *recurring* polls live in
    # `connected` (see below) - not here - so they can't accumulate.
    update_source_info
  end

  # The recurring background polls are registered here rather than in
  # `on_authenticated`. `connected` runs `schedule.clear` (via super) on every
  # (re)connect, so the schedules are re-armed cleanly. `on_authenticated` fires
  # on the independent HTTP-auth lifecycle, so registering recurring tasks there
  # meant each re-auth added schedules that were never cleared - leaking
  # schedules (and, under the old per-timer scheduler, a fiber each).
  def connected
    super

    # Background poll for subscription changes.
    schedule.every(1.hour) do
      query("/XioSubscription/Subscriptions", priority: 5) do |subs|
        self[:subscriptions] = @subscriptions = subs.as_h
      end
    end

    # Background poll to remain in sync with any external routing changes
    schedule.every(5.minutes) { update_source_info }
  end

  def switch_to(input : Input)
    switch_layer input
  end

  protected def switch_layer(input : Input, layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All

    do_switch = case input.downcase
                when "none", "break", "clear", "blank", "black"
                  blank layer
                when "input1", "hdmi", "hdmi1"
                  switch_local "Input1", layer
                when "input2", "hdmi2"
                  switch_local "Input2", layer
                when "input3", "usbc1"
                  switch_local "USB-C1", layer
                when "input4", "usbc2"
                  switch_local "USB-C2", layer
                else
                  switch_stream input, layer
                end

    do_switch.try &.get
    update_source_info
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    switch_layer map.keys.first, layer
  end

  def output(state : Bool)
    logger.debug { "#{state ? "enabling" : "disabling"} output sync" }

    ws_update(
      "/AudioVideoInputOutput/Outputs",
      [{
        Ports: [{
          Hdmi: {IsOutputDisabled: !state},
        }],
      }],
      name: :output
    )
  end

  def output_with_index(state : Bool, output_index : Int32, port_index : Int32?)
    logger.debug { "#{state ? "enabling" : "disabling"} output sync for output #{output_index}#{port_index ? " port #{port_index}" : ""}" }
    # /AudioVideoInputOutput/Outputs/x/Ports/x/Hdmi/   https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/AudioVideoInputOutput.htm
    ws_update(
      "/AudioVideoInputOutput/Outputs/#{output_index}/Ports#{port_index ? "/#{port_index}/" : "/"}Hdmi/IsOutputDisabled",
      !state,
      name: :output
    )
  end

  # aspect ratio defined in nvx_rx_models
  def aspect_ratio(mode : AspectRatio)
    logger.debug { "setting output aspect ratio mode: #{mode}" }

    ws_update(
      "/AudioVideoInputOutput/Outputs",
      [{
        Ports: [{
          AspectRatioMode: mode,
        }],
      }],
      name: :aspect_ratio
    )
  end

  protected def query_device_name
    query("/Localization/Name", name: "device_name") do |name|
      self["device_name"] = name
    end
  end

  def query_osd_text
    query("/Osd/Text", name: "osd_text") do |text|
      self[:osd_text] = text
    end
  end

  # Shared method to process input sync status
  private def process_input_sync_status(inputs_hash)
    return unless inputs_hash

    inputs_hash.each do |input_name, input_val|
      friendly_input = input_val["UserSpecifiedName"].as_s.downcase.delete(" ")
      key = "#{friendly_input}_sync"

      # Default to false
      sync_detected = false

      if ports = input_val.dig?("InputInfo", "Ports").try &.as_h?
        ports.each do |_, port_val|
          vr = port_val.dig?("VerticalResolution").try &.as_i?
          if vr && vr >= MIN_SYNC_VERTICAL
            sync_detected = true
            break
          end
        end
      end

      self[key] = sync_detected
    end
  end

  protected def query_input_state
    query("/AvioV2/Inputs", name: "input_states", priority: 5) do |inputs, _task|
      process_input_sync_status(inputs.as_h?) if inputs
    end
  end

  def set_osd_text(text : String, enabled : Bool = true)
    ws_update "/Osd/Text", text, name: :set_osd_text
    ws_update "/Osd/IsEnabled", enabled, name: :set_osd_enabled
  end

  @[Security(Level::Support)]
  def enable_background_image(state : Bool = true, output_index : Int32? = nil)
    output_index ||= 1
    ws_update "/BackgroundImage/Outputs/Output#{output_index}/IsEnabled", state, name: "set_output#{output_index}_image_enabled"
  end

  # The decoder hosts uploaded background images locally under this path,
  # using fixed image "slots" (Image01..ImageNN). We always use Image01.
  UPLOAD_DIR  = "/data/web/tmp/Images/Local/"
  UPLOAD_SLOT = "Image01"

  BACKGROUND_IMAGE_COMMAND_TIMEOUT = 5.seconds
  BACKGROUND_IMAGE_UPLOAD_TIMEOUT  = 60.seconds
  BACKGROUND_IMAGE_OUTPUT_TIMEOUT  = 15.seconds
  BACKGROUND_IMAGE_RETRY_BUDGET    = 105.seconds
  BACKGROUND_IMAGE_POLL_INTERVAL   = 1.second

  @uploading_background_image = Atomic(Bool).new(false)

  @[Security(Level::Support)]
  def background_image_ready?(output_index : Int32? = nil) : Bool
    output = background_image_output(output_index || 1)
    return false unless output["HostBackgroundImage"]? == "Local"

    image_name = output.dig?("Local", "ImageName").try(&.as_s?).presence
    return false unless image_name && background_image_selected?(output, image_name)

    stored_background_image_ready?(image_name)
  end

  @[Security(Level::Administrator)]
  def set_background_image(url : String, output_index : Int32? = nil) : Nil
    output_index ||= 1
    uri = begin
      URI.parse(url)
    rescue URI::Error
      raise ArgumentError.new("invalid background image URL")
    end
    unless uri.scheme.in?({"http", "https"}) && uri.host.presence && uri.path.presence
      raise ArgumentError.new("invalid background image URL")
    end

    # The NVX's remote-server image pull is too limited, so instead we download
    # the image ourselves and upload it onto the device for local hosting.
    image_name = File.basename(uri.path)
    raise ArgumentError.new("missing background image filename") if image_name.in?({"", "/", ".", ".."})
    raise "another background image upload is in progress" if @uploading_background_image.swap(true)

    begin
      # Both attempts share a polling budget. The HTTP requests retain their
      # transport timeouts.
      deadline = Time.instant + BACKGROUND_IMAGE_RETRY_BUDGET
      image_stored = false
      2.times do |attempt|
        begin
          unless image_stored
            upload_local_image(uri, image_name)
            storage_deadline = Math.min(deadline, Time.instant + BACKGROUND_IMAGE_UPLOAD_TIMEOUT)
            wait_for_background_image(storage_deadline, "background image #{image_name} to be stored") do
              stored_background_image_ready?(image_name, raise_on_error: true)
            end
            image_stored = true
          end

          select_background_image(image_name, output_index, deadline)
          return
        rescue error
          raise error unless attempt.zero? && Time.instant + BACKGROUND_IMAGE_COMMAND_TIMEOUT < deadline

          if image_stored
            logger.warn { "retrying background image selection on Output#{output_index}" }
          else
            # The decoder may have received the first upload even if its
            # response or readiness check failed. Avoid its filename cache.
            image_name = "#{Random::Secure.hex(8)}#{File.extname(image_name)}"
            logger.warn { "retrying background image upload as #{image_name}" }
          end
        end
      end
    ensure
      @uploading_background_image.set(false)
    end
  end

  @[Security(Level::Administrator)]
  def set_background_image_name(image_name : String, output_index : Int32? = nil) : Nil
    output_index ||= 1
    ws_update "/BackgroundImage/Outputs/Output#{output_index}/Local/ImageName", image_name, name: "set_output#{output_index}_image"
  end

  private def select_background_image(image_name : String, output_index : Int32, deadline : Time::Instant) : Nil
    raise "timed out before selecting background image on Output#{output_index}" if Time.instant >= deadline

    output = background_image_output(output_index)
    unless output.dig?("Local", "ImageName") == image_name
      apply_background_image_property(output_index, "Local/ImageName", image_name, deadline)
    end
    unless output["HostBackgroundImage"]? == "Local"
      apply_background_image_property(output_index, "HostBackgroundImage", "Local", deadline)
    end

    output_deadline = Math.min(deadline, Time.instant + BACKGROUND_IMAGE_OUTPUT_TIMEOUT)
    wait_for_background_image(output_deadline, "background image #{image_name} to be selected on Output#{output_index}") do
      background_image_selected?(background_image_output(output_index), image_name)
    end
  end

  private def background_image_output(output_index : Int32) : JSON::Any
    # A push notification can update just one property at the same path.
    read_background_image("/BackgroundImage/Outputs/Output#{output_index}") do |output|
      !output["HostBackgroundImage"]?.nil? && !output["Local"]?.nil? && !output["StatusCode"]?.nil?
    end
  end

  private def background_image_selected?(output : JSON::Any, image_name : String) : Bool
    output["HostBackgroundImage"]? == "Local" &&
      output.dig?("Local", "ImageName") == image_name &&
      !output.dig?("Local", "PreviewImage").try(&.as_s?).presence.nil? &&
      output["StatusCode"]?.try(&.as_i?) != -1 &&
      !output["StatusMessage"]?.try(&.as_s?).in?({"Pending", "Processing", "Error"})
  end

  private def stored_background_image_ready?(image_name : String, *, raise_on_error : Bool = false) : Bool
    inventory = read_background_image("/ImageMgmnt") { |state| !state["Version"]?.nil? }
    local_images = inventory["LocalImages"]?.try(&.as_h?)
    return false unless local_images

    local_images.values.any? do |image|
      next false unless image["Name"]? == image_name || image["UploadFile"]? == image_name

      status = image["UploadStatus"]?.try(&.as_s?).presence
      if raise_on_error && status.in?({"Error", "InvalidFile"})
        detail = image["DetailedMessage"]?.try(&.as_s?).presence || status
        raise "device could not store background image #{image_name}: #{detail}"
      end

      image["Name"]? == image_name &&
        !image["PreviewImage"]?.try(&.as_s?).presence.nil? &&
        status.in?({nil, "Ready"})
    end
  end

  private def wait_for_background_image(deadline : Time::Instant, description : String, &ready : -> Bool) : Nil
    while Time.instant < deadline
      return if ready.call
      remaining = deadline - Time.instant
      break unless remaining.positive?

      sleep Math.min(remaining, BACKGROUND_IMAGE_POLL_INTERVAL)
    end
    raise "timed out waiting for #{description}"
  end

  private def read_background_image(path : String, &matching : JSON::Any -> Bool) : JSON::Any
    task = query(path, matching: matching, timeout: BACKGROUND_IMAGE_COMMAND_TIMEOUT, retries: 0) { }
    background_image_response(task, "read #{path}")
  end

  private def apply_background_image_property(output_index : Int32, property : String, value : String, deadline : Time::Instant) : Nil
    path = "/BackgroundImage/Outputs/Output#{output_index}/#{property}"
    operation = "set #{path}"
    timeout = Math.min(BACKGROUND_IMAGE_COMMAND_TIMEOUT, deadline - Time.instant)
    raise "timed out before attempting to #{operation}" unless timeout.positive?

    task = ws_update(path, value, timeout: timeout, retries: 0)
    response = background_image_response(task, operation, timeout)
    results = background_image_results(response, "BackgroundImage")
    full_path = "Device#{path.gsub('/', '.')}"
    parent_path, _, property_name = full_path.rpartition('.')
    result = results.find do |entry|
      result_path = entry["Path"]?
      result_property = entry["Property"]?
      (result_path == parent_path && result_property == property_name) ||
        (result_property.nil? && result_path.in?({full_path, "Device.BackgroundImage"}))
    end
    raise "device did not acknowledge #{operation}" unless result

    # If the property already changed, the readback still has to match.
    unless result["StatusId"]? == 0 || result["StatusInfo"]? == "Value is same as previous"
      raise "device rejected #{operation}: #{background_image_result_detail(result)}"
    end
  end

  private def background_image_response(task : ::PlaceOS::Driver::Task, operation : String, timeout : Time::Span = BACKGROUND_IMAGE_COMMAND_TIMEOUT) : JSON::Any
    # A queued command can also time out before transmission if the device
    # disconnects or other commands are pending.
    watchdog = Tasker.in(timeout) { task.abort("timed out waiting to #{operation}") }
    task.get(true)
    raise "could not #{operation}: #{task.payload}" unless task.state.success?

    JSON.parse(task.payload)
  ensure
    watchdog.try &.cancel
  end

  private def background_image_results(response : JSON::Any, target : String) : Array(JSON::Any)
    actions = response["Actions"]?.try(&.as_a?) || [] of JSON::Any
    actions.select { |action| action["TargetObject"]? == target }.flat_map do |action|
      action["Results"]?.try(&.as_a?) || [] of JSON::Any
    end
  end

  private def background_image_result_detail(result : JSON::Any) : String
    result["StatusInfo"]?.try(&.as_s?).presence || "status #{result["StatusId"]?}"
  end

  # Streams the image from *uri* straight into a multipart/form-data upload to
  # the decoder, storing it in the local image slot (`UPLOAD_SLOT`).
  #
  # The download response body is piped directly into the multipart body as it
  # arrives, so we never hold a second copy of the image data.
  protected def upload_local_image(uri : URI, image_name : String) : Nil
    request_payload = %({"Device":{"ImageMgmnt":{"LocalImages":{"#{UPLOAD_SLOT}":{"UploadFile":#{image_name.to_json},"UploadFilePath":#{UPLOAD_DIR.to_json}}}}}})

    body = IO::Memory.new
    tls = uri.scheme == "https" ? OpenSSL::SSL::Context::Client.insecure : nil

    # Use an explicit boundary so we can advertise it *unquoted* in the
    # Content-Type header below. The NVX's multipart parser does not strip
    # quotes (like a browser/curl), so the quoted form `HTTP::FormData` emits
    # by default isn't recognised as an upload - the device then falls back to
    # a plain config-set and rejects the payload ("unsupported property").
    boundary = MIME::Multipart.generate_boundary

    HTTP::Client.new(uri, tls: tls) do |client|
      client.connect_timeout = 10.seconds
      client.read_timeout = 10.seconds
      client.get(uri.request_target) do |source|
        raise "failed to download background image #{image_name}: HTTP #{source.status_code}" unless source.success?

        # PlaceOS commonly serves a generic content type, while the NVX
        # requires the MIME type for the image upload part.
        mime = MIME.from_filename?(image_name).presence || source.headers["Content-Type"]?.presence || "application/octet-stream"

        HTTP::FormData.build(body, boundary) do |form|
          form.field "UploadFilePath", UPLOAD_DIR
          form.field "RequestPayload", request_payload
          form.file "UploadImage", source.body_io, HTTP::FormData::FileMetadata.new(filename: image_name), HTTP::Headers{"Content-Type" => mime}
        end
      end
    end

    response = post("/Device", body: body.to_slice, headers: HTTP::Headers{
      "Content-Type"     => "multipart/form-data; boundary=#{boundary}",
      "CREST-XSRF-TOKEN" => @xsrf_token,
    })

    raise "failed to upload background image #{image_name}: HTTP #{response.status_code}" unless response.success?

    results = background_image_results(JSON.parse(response.body), "ImageMgmnt")
    upload_result = results.find do |result|
      result["Path"]? == "Device.ImageMgmnt.LocalImages.#{UPLOAD_SLOT}" && result["Property"]? == "UploadFile"
    end
    raise "device did not acknowledge upload of background image #{image_name}" unless upload_result

    results.each do |result|
      next if result["StatusId"]? == 0

      if result["StatusId"]? == 9
        if result["Property"]? == "UploadFilePath" && result["StatusInfo"]? == "File Upload Operation Succeeded"
          next
        end
        next if result == upload_result && result["StatusInfo"]? == "#{image_name}:Success"
      end

      raise "device rejected upload background image #{image_name}: #{background_image_result_detail(result)}"
    end
  end

  protected def switch_stream(stream_reference : String | Int32, layer : SwitchLayer)
    uuid = uuid_for stream_reference

    logger.debug do
      subscription = @subscriptions[uuid].as_h
      id, name = subscription.values_at "Position", "SessionName"
      "switching to Stream#{id} (#{name}) on layer #{layer}"
    end

    if layer.all? || layer.video?
      ws_update "/DeviceSpecific/VideoSource", "Stream", name: :input_video
      resp = ws_update "/AvRouting/Routes", { {VideoSource: uuid} }, name: :switch_video
    end

    if @audio_follows_video
      ws_update "/DeviceSpecific/AudioSource", "AudioFollowsVideo", name: :input_audio
      resp = ws_update "/AvRouting/Routes", { {AudioSource: uuid} }, name: :switch_audio
    elsif layer.all? || layer.audio?
      ws_update "/DeviceSpecific/AudioSource", "Stream", name: :input_audio
      resp = ws_update "/AvRouting/Routes", { {AudioSource: uuid} }, name: :switch_audio
    end

    resp
  end

  protected def switch_local(input, layer : SwitchLayer)
    logger.debug { "switching to #{input}" }

    if layer.all? || layer.video?
      resp = ws_update "/DeviceSpecific/VideoSource", input, name: :input_video
    end

    if @audio_follows_video
      resp = ws_update "/DeviceSpecific/AudioSource", "AudioFollowsVideo", name: :input_audio
    elsif layer.all? || layer.audio?
      resp = ws_update "/DeviceSpecific/AudioSource", input, name: :input_audio
    end

    resp
  end

  protected def blank(layer : SwitchLayer)
    logger.debug { "blanking output" }

    if layer.all? || layer.video?
      ws_update "/DeviceSpecific/VideoSource", "None", name: :input_video
      resp = ws_update "/AvRouting/Routes", { {VideoSource: ""} }, name: :switch_video
    end

    if @audio_follows_video
      ws_update "/DeviceSpecific/AudioSource", "AudioFollowsVideo", name: :input_audio
      resp = ws_update "/AvRouting/Routes", { {AudioSource: ""} }, name: :switch_audio
    elsif layer.all? || layer.audio?
      ws_update "/DeviceSpecific/AudioSource", "None", name: :input_audio
      resp = ws_update "/AvRouting/Routes", { {AudioSource: ""} }, name: :switch_audio
    end

    resp
  end

  # Decoders must first subscribe to encoders they need to receive signals
  # from. Switching is then based on device UUID's.
  #
  # The deivce web UI's (and presumbly XIO director) show these as selectable
  # 'inputs' - this mapping allows sources to either be specified as a UUID,
  # or their 'input number' as displayed with Crestron tooling.
  #
  # Alternatively, if a string is provided the list of search props will be
  # searched for a match.
  protected def uuid_for(reference : String)
    if /Stream(\d+)/i =~ reference
      # grab the matching data https://crystal-lang.org/api/latest/Regex.html
      id = $~[1].to_i
      return uuid_for id
    end

    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/XioSubscription.htm?Highlight=XioSubscription
    subscriptions = @subscriptions

    if subscriptions.has_key? reference
      uuid = reference
    else
      {"MulticastAddress", "SessionName"}.each do |prop|
        if result = subscriptions.find { |_, x| x.as_h[prop]? == reference }
          uuid = result[0]
        end
        break if uuid
      end
    end

    raise ArgumentError.new("input #{reference} not subscribed") if uuid.nil?

    uuid
  end

  protected def uuid_for(reference : Int32)
    subscriptions = @subscriptions

    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/XioSubscription.htm?Highlight=XioSubscription
    if result = subscriptions.find { |_, x| x.as_h["Position"]? == reference }
      uuid = result[0]
    end

    raise ArgumentError.new("input #{reference} not subscribed") if uuid.nil?

    uuid
  end

  enum SourceType
    Audio
    Video
  end

  # Build friendly source names based on a device state
  #
  # Maps all streams into `Stream1`...`StreamN` style names based on
  # subscriptions. Local inputs (`Input1`, `Input2`, `AnalogueAudio` etc) are
  # left untouched.
  protected def query_source_name_for(type : SourceType)
    type_downcase = type.to_s.downcase

    # "ActiveAudioSource":"Input1|Input2|Analog|PrimaryAudio|SecondaryAudio",
    # "ActiveVideoSource":"None|Input1|Input2|Stream",
    query("/DeviceSpecific/Active#{type}Source", name: "#{type_downcase}_source", priority: 0) do |source_name|
      if source_name.as_s.includes? "Stream"
        # "Routes": [{
        #   "AudioSource": "07147488-9e0b-11e7-abc4-cec278b6b50a",
        #   "AutomaticStreamRoutingEnabled": false,
        #   "Name": "PrimaryStream",
        #   "UniqueId": "cc063ec3-d135-4413-9ee9-5a9264b5642c",
        #   "VideoSource": "07147488-9e0b-11e7-abc4-cec278b6b50a"
        # }]
        query("/AvRouting/Routes", name: :routes, priority: 1) do |routes|
          uuid = routes.dig?(0, "#{type}Source").try &.as_s?
          # FIXME: provide 'Stream1..n' rather than uuids
          self["#{type_downcase}_source"] = uuid.presence ? "Stream-#{uuid}" : "None"
        end
      else
        self["#{type_downcase}_source"] = source_name
      end
    end
  end

  # Query the device for the current source state and update status vars.
  protected def update_source_info
    query_source_name_for(:video)
    query_source_name_for(:audio)
    query_device_name
    query_osd_text
    query_input_state
  end

  def received(data, task)
    super

    raw_json = String.new data

    # The device sometimes bundles multiple JSON objects into a single frame
    # separated by blank lines, so parse each line independently.
    raw_json.each_line do |line|
      line = line.strip
      next if line.empty?

      begin
        json = JSON.parse(line)
        if inputs = json.dig?("Device", "AvioV2", "Inputs").try &.as_h?
          process_input_sync_status(inputs)
        end
      rescue e
        logger.debug { "unsolicited parse error: #{e.message}" }
      end
    end
  end

  def __stat_mem__
    ::PlaceOS::Driver::Stats.memory_usage
  end

  def __stat_fiber__
    ::PlaceOS::Driver::Stats.fiber_breakdown
  end
end
