require "./cres_next"
require "placeos-driver/interface/switchable"

class Crestron::NvxRx < Crestron::CresNext # < PlaceOS::Driver
  alias Input = String | Int32?
  include PlaceOS::Driver::Interface::InputSelection(Input)
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

  def connected
    # NVX hardware can be confiured a either a RX or TX unit - check this
    # device is in the correct mode.
    # https://sdkcon78221.crestron.com/sdk/DM_NVX_REST_API/Content/Topics/Objects/DeviceSpecific.htm?Highlight=DeviceMode
    query("/DeviceSpecific/DeviceMode") do |mode|
      # "DeviceMode":"Transmitter|Receiver",
      next if mode == "Receiver"
      logger.warn { "device configured as a #{mode}" }
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
    input = input.downcase if input.is_a?(String)
    do_switch = case input
                when "none", "break", "clear", "blank", "black", nil, 0
                  blank
                when "input1", "hdmi", "hdmi1"
                  switch_local "Input1"
                when "input2", "hdmi2"
                  switch_local "Input2"
                else
                  switch_stream input
                end

    do_switch.get
    update_source_info
  end

  def output(state : Bool)
    logger.debug { "#{state ? "enabling" : "disabling"} output sync" }

    update(
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

    update(
      "/AudioVideoInputOutput/Outputs",
      [{
        Ports: [{
          AspectRatioMode: mode,
        }],
      }],
      name: :aspect_ratio
    )
  end

  protected def switch_stream(stream_reference : String | Int32)
    uuid = uuid_for stream_reference

    logger.debug do
      subscription = @subscriptions[uuid].as_h
      id, name = subscription.values_at "Position", "SessionName"
      "switching to Stream#{id} (#{name})"
    end

    payload = {
      AvRouting: {
        Routes: [{VideoSource: uuid, AudioSource: uuid}],
      },
      DeviceSpecific: {
        VideoSource: "Stream",
        AudioSource: "AudioFollowsVideo",
      },
    }

    update "/", payload, name: :switch
  end

  protected def switch_local(input)
    logger.debug { "switching to #{input}" }
    update(
      "/DeviceSpecific",
      {VideoSource: input, AudioSource: "AudioFollowsVideo"},
      name: :switch
    )
  end

  protected def blank
    logger.debug { "blanking output" }

    payload = {
      AvRouting: {
        Routes: [{VideoSource: "", AudioSource: ""}],
      },
      DeviceSpecific: {
        VideoSource: "None",
        AudioSource: "AudioFollowsVideo",
      },
    }

    update("/", payload, name: :switch)
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
        if result = subscriptions.find { |_, x| x.as_h[prop] == reference }
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
    if result = subscriptions.find { |_, x| x.as_h["Position"] == reference }
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
  end
end
