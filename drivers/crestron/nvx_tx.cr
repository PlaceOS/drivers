require "./cres_next"
require "placeos-driver/interface/switchable"

class Crestron::NvxTx < Crestron::CresNext # < PlaceOS::Driver
  enum Input
    None
    Input1
    Input2
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)
  include Crestron::Transmitter

  descriptive_name "Crestron NVX Transmitter"
  generic_name :Encoder
  description <<-DESC
    Crestron NVX network media encoder.
  DESC

  uri_base "wss://192.168.0.5/websockify"

  def connected
    # NVX hardware can be confiured a either a RX or TX unit - check this
    # device is in the correct mode.
    query("/DeviceSpecific/DeviceMode") do |mode|
      # "DeviceMode":"Transmitter|Receiver",
      next if mode == "Transmitter"
      logger.warn { "device configured as a #{mode}" }
      self[:WARN] = "device configured as a #{mode}. Expecting Transmitter"
    end

    # Background poll to remain in sync with any external routing changes
    schedule.every(5.minutes, immediate: true) { update_source_info }
  end

  def switch_to(input : Input)
    logger.debug { "switching to #{input}" }
    update(
      "/DeviceSpecific",
      {VideoSource: input, AudioSource: "AudioFollowsVideo"},
      name: :switch
    ).get
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

  def multicast_address(address : String)
    logger.debug { "setting multicast address to #{address}" }
    update("/StreamTransmit/Streams", [{MulticastAddress: address}], name: :multicast_address)
  end

  def emulate_input_sync(state : Bool = true, idx : Int32 = 1)
    self["input_#{idx}_sync"] = state
  end

  # Build friendly source names based on a device state.
  protected def query_source_name_for(type : SourceType)
    type_downcase = type.to_s.downcase
    query("/DeviceSpecific/Active#{type}Source", name: "#{type_downcase}_source") do |source_name|
      self["#{type_downcase}_source"] = source_name
    end
  end

  protected def query_multicast_address
    query("/StreamTransmit/Streams", name: "streams") do |streams|
      self["multicast_address"] = streams.dig(0, "MulticastAddress")
    end
  end

  protected def query_stream_name
    query("/Localization/Name", name: "stream_name") do |name|
      self["stream_name"] = name
    end
  end

  # Query the device for the current source state and update status vars.
  protected def update_source_info
    query_stream_name
    query_multicast_address
    query_source_name_for(:video)
    query_source_name_for(:audio)
  end

  def received(data, task)
    raw_json = String.new data
    logger.debug { "Crestron sent: #{raw_json}" }

    return unless raw_json.includes? "AudioVideoInputOutput"
    payload = JSON.parse(raw_json)

    # we're checking if a device is plugged into a port
    # Device/AudioVideoInputOutput/Inputs/0/Ports/0/IsSyncDetected
    if av_inputs = payload.dig?("Device", "AudioVideoInputOutput", "Inputs").try &.as_a?
      av_inputs.each do |input|
        name = input["Name"]?.try(&.as_s) || ""

        # Device returns inputs as "input0", "input1" ... "inputN" within
        # long poll responses, but appears to reference these same inputs
        # as "input-1", "input-2" ... "input-N" within direct state queries.
        idx = case name
              when /input(\d+)/
                # increment by 1
                $~[1].to_i.succ
              when /input-(\d+)/
                $~[1].to_i
              else
                # There also appears to be situations where no name is
                # returned. As only the first input is in use across all
                # encoders, default to input 1 as a nasty hack around
                # this craziness.
                1
              end

        sync = input.dig?("Ports", 0, "IsSyncDetected").try &.as_bool?
        self["input_#{idx}_sync"] = sync unless sync.nil?
      end
    end
  end
end
