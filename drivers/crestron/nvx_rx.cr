require "./cres_next"
require "placeos-driver/interface/switchable"

class Crestron::NvxRx < Crestron::CresNext # < PlaceOS::Driver
  alias Input = String
  alias Output = Int32
  include Interface::Switchable(Input, Output)
  include Interface::InputSelection(Input)
  include Crestron::Receiver

  descriptive_name "Crestron NVX Receiver"
  generic_name :Decoder
  description <<-DESC
    Crestron NVX network media decoder.
  DESC

  uri_base "wss://192.168.0.5/websockify"

  default_settings({
    username: "admin",
    password: "admin",
  })

  @subscriptions : Hash(String, JSON::Any) = {} of String => JSON::Any
  @audio_follows_video : Bool = true

  def connected
    super
    audio_follows_video = setting?(Bool, :audio_follows_video)
    @audio_follows_video = audio_follows_video.nil? ? true : audio_follows_video

    # NVX hardware can be confiured a either a RX or TX unit - check this
    # device is in the correct mode.
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

    # Background poll for subscription changes.
    schedule.every(1.hour) do
      query("/XioSubscription/Subscriptions", priority: 5) do |subs|
        self[:subscriptions] = @subscriptions = subs.as_h
      end
    end

    # Background poll to remain in sync with any external routing changes
    schedule.every(5.minutes, immediate: true) { update_source_info }
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

  # Build friendly source names based on a device state.
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
  end
end
