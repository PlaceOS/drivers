require "placeos-driver"
require "./hub_dsp_models"

# Documentation: https://docs.catchbox.com/
# V2.0 API Command List: https://docs.google.com/spreadsheets/d/10aOYyVSSGEU3oRSo80UGlRG2WUvq-uPR/edit

class Catchbox::HubDSP < PlaceOS::Driver
  # Discovery Information
  udp_port 39030
  descriptive_name "Catchbox Hub DSP Receiver"
  description "Controls Catchbox Hub DSP receiver for wireless microphone management. Configure IP address and UDP port in device settings."
  generic_name :Mixer

  # Error Codes
  # 0	OK (Command executed successfully)
  # 405	VALUE_OUT_OF_BOUNDS (Supplied value is outside the allowed parameter range)
  # 410	INCORRECT_VALUE (Supplied value has incorrect formatting)
  # 415	UNREACHABLE_ENDPOINT (Returned when requesting info from transmitters, when there is no RF link)
  # 425	MALFORMED_COMMAND (Command is improperly formatted)
  # 430	UNSUPPORTED_FEATURE (Returned when trying to get or set features which are not present on given product e.g. setting Mute button enable feature for Cube)

  default_settings({
    subscribe_mics_status:         true,
    mics_battery_polling_interval: 60000,
    mics_link_polling_interval:    30000,
  })

  @battery_poll_interval : Int32 = 0
  @link_poll_interval : Int32 = 0
  @mic_subscription : Bool = false

  def on_load
    transport.tokenizer = nil

    on_update
  end

  def on_update
    # Update poll interval in ms
    @battery_poll_interval = setting?(Int32, :mics_battery_polling_interval) || 60000
    @link_poll_interval = setting?(Int32, :mics_link_polling_interval) || 30000
    @mic_subscription = setting?(Bool, :subscribe_mics_status) || false

    # resub with new values
    subscribe_mic_battery_levels(@battery_poll_interval, @mic_subscription)
    subscribe_mic_link_state(@link_poll_interval, @mic_subscription)
  end

  def connected
    logger.debug { "Connected to Catchbox Hub DSP" }

    # subscriptions
    subscribe_mic_battery_levels(@battery_poll_interval, @mic_subscription)
    subscribe_mic_link_state(@link_poll_interval, @mic_subscription)

    # query device info once
    schedule.in(5.seconds) do
      query_rx_device_status
      query_tx_device_status_all
      query_network_status
    end
  end

  def disconnected
    logger.debug { "Disconnected to Catchbox Hub DSP" }
  end

  def manual_send(request : JSON::Any)
    json = request.to_json
    logger.debug { "Sending Manual Request: #{json}" }
    send(json.to_slice)
  end

  def send_request(request : String)
    logger.debug { "Sending Request: #{request}" }
    send(request)
  end

  def received(data, task)
    data_string = String.new(data).strip
    logger.debug { "Received: #{data_string}" }
    response = ApiResponse.from_json(data_string)

    response.rx.try do |rx|
      rx.device.try { |d| process_device(d) }
      rx.network.try { |n| process_network(n) }
      rx.audio.try { |a| process_audio(a) }
    end

    [
      {"tx1", response.tx1},
      {"tx2", response.tx2},
      {"tx3", response.tx3},
      {"tx4", response.tx4},
    ].each do |(name, tx)|
      tx.try do |t|
        t.device.try { |d| process_mic(d, name) }
      end
    end

    task.try(&.success)
  end

  private def process_device(device : Device)
    # process RX info
    self[:rx_device_type] = device.device_type if device.device_type
    self[:rx_device_name] = device.name if device.name
    self[:rx_firmware] = device.firmware_info if device.firmware_info
    self[:rx_serial] = device.serial if device.serial

    # process RX link info
    [
      {device.mic1_link_state, 1},
      {device.mic2_link_state, 2},
      {device.mic3_link_state, 3},
      {device.mic4_link_state, 4},
    ].each do |(state, num)|
      next unless state

      self["mic#{num}_link_state"] = state
      if state.in?(LinkState::Connected, LinkState::Charging)
        query_tx_device_status(num)
      end
    end
  end

  private def process_network(network : Network)
    self[:ip_address] = network.ip_address if network.ip_address
    self[:ip_mode] = network.ip_mode if network.ip_mode
    self[:mac] = network.mac if network.mac
    self[:subnet] = network.subnet if network.subnet
    self[:gateway] = network.gateway if network.gateway
  end

  private def process_mic(device : Device, tx : String)
    self["#{tx}_battery_level"] = device.battery if device.battery
    self["#{tx}_name"] = device.name if device.name
    self["#{tx}_firmware"] = device.firmware_info if device.firmware_info
    self["#{tx}_rssi"] = device.rssi if device.rssi
    self["#{tx}_serial"] = device.serial if device.serial
  end

  private def process_audio(audio : Audio)
    # TODO #
  end

  # # Subscriptions ##

  # Microphone Mute State
  def subscribe_mic_mute_states(period_ms : Int32, enable : Bool)
    ["mic1", "mic2", "mic3", "mic4"].each do |mic|
      sub = {
        "subscribe" => [{
          "#"  => {"enable" => enable, "period_ms" => period_ms},
          "rx" => {"audio" => {"input" => {mic => {"mute" => nil}}}},
        }],
      }
      send_request(sub.to_json)
    end
  end

  # Microphone Battery Status
  def subscribe_mic_battery_levels(period_ms : Int32, enable : Bool)
    (1..4).each do |num|
      sub = {
        "subscribe" => [{
          "#"        => {"enable" => enable, "period_ms" => period_ms},
          "tx#{num}" => {"device" => {"battery" => nil}},
        }],
      }
      send_request(sub.to_json)
    end
  end

  # Microphone Link Status
  def subscribe_mic_link_state(period_ms : Int32, enable : Bool)
    ["mic1", "mic2", "mic3", "mic4"].each do |mic|
      sub = {
        "subscribe" => [{
          "#"  => {"enable" => enable, "period_ms" => period_ms},
          "rx" => {"device" => {"#{mic}_link_state" => nil}},
        }],
      }
      send_request(sub.to_json)
    end
  end

  # # Query ##

  def query_rx_device_status
    ["name", "device_type", "firmware_info", "serial"].each do |field|
      query = ({"rx" => {"device" => {field => nil}}})
      send_request(query.to_json)
    end
  end

  def query_tx_device_status_all
    (1..4).each do |num|
      ["name", "firmware_info", "serial"].each do |field|
        query = ({"tx#{num}" => {"device" => {field => nil}}})
        send_request(query.to_json)
      end
    end
  end

  def query_tx_device_status(index : Int32)
    ["name", "firmware_info", "serial"].each do |field|
      query = ({"tx#{index}" => {"device" => {field => nil}}})
      send_request(query.to_json)
    end
  end

  def query_network_status
    ["mac", "ip_mode", "ip_address", "subnet", "gateway"].each do |field|
      query = ({"rx" => {"network" => {field => nil}}})
      send_request(query.to_json)
    end
  end
end
