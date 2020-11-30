require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Nec::Projector < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    VGA         = 0x01
    RGBHV       = 0x02
    Composite   = 0x06
    SVideo      = 0x0B
    Component   = 0x10
    Component2  = 0x11
    HDMI        = 0x1A
    HDMI2       = 0x1B
    DisplayPort = 0xA6
    LAN         = 0x20
    Viewer      = 0x1F
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 7142
  descriptive_name "NEC Projector"
  generic_name :Display

  default_settings({
    volume_min: 0,
    volume_max: 63,
  })

  @power_target : Bool? = nil
  @input_target : Input? = nil
  @volume_min : Int32 = 0
  @volume_max : Int32 = 63

  DELIMITER = 0x0D_u8

  def on_load
    # Communication settings
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
    self[:error] = [] of String
    on_update
  end

  def on_update
    @power_target = nil
    @input_target = nil
    @volume_min = setting(Int32, :volume_min)
    @volume_max = setting(Int32, :volume_max)
  end

  def connected
    schedule.every(50.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
    # Disconnect often occurs on power off
    # We may have not received a status response before the disconnect occurs
    self[:power] = false
  end

  # Command Listing
  # Second byte used to detect command type
  COMMAND = {
    # Mute controls
    mute_picture:    "$02,$10,$00,$00,$00,$12",
    unmute_picture:  "$02,$11,$00,$00,$00,$13",
    mute_audio_cmd:  "02 12 00 00 00 14",
    unmute_audio:    "02 13 00 00 00 15",
    mute_onscreen:   "02 14 00 00 00 16",
    unmute_onscreen: "02 15 00 00 00 17",

    freeze_picture:   "$01,$98,$00,$00,$01,$01,$9B",
    unfreeze_picture: "$01,$98,$00,$00,$01,$02,$9C",

    status_lamp:  Bytes[0x00, 0x81, 0x00, 0x00, 0x00, 0x81], # Running sense (ret 81)
    status_input: "$00,$85,$00,$00,$01,$02,$88", # Input status (ret 85)
    status_mute:  "00 85 00 00 01 03 89", # MUTE STATUS REQUEST (Check 10H on byte 5)
    status_error: "00 88 00 00 00 88",     # ERROR STATUS REQUEST (ret 88)
    status_model: "00 85 00 00 01 04 8A",  # request model name (both of these are related)

    # lamp hours / remaining information
    lamp_information:      "03 8A 00 00 00 8D", # LAMP INFORMATION REQUEST
    filter_information:    "03 8A 00 00 00 8D",
    projector_information: "03 8A 00 00 00 8D",

    background_black: "$03,$B1,$00,$00,$02,$0B,$01,$C2", # set mute to be a black screen
    background_blue:  "$03,$B1,$00,$00,$02,$0B,$00,$C1", # set mute to be a blue screen
    background_logo:  "$03,$B1,$00,$00,$02,$0B,$02,$C3", # set mute to be the company logo
  }

  {% for name, data in COMMAND %}
    def {{name.id}}(**options)
      send(COMMAND[{{name.id}}], **options, name: {{name.id.stringify}})
    end
  {% end %}

  def volume(vol : Int32)
    vol = vol.clamp(@volume_min, @volume_max)
    # volume base command                           D1    D2    D3   D4    D5 + CKS
    command = Bytes[0x03, 0x10, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00, vol, 0x00]
    # D3 = 00 (absolute vol) or 01 (relative vol)
    # D4 = value (lower bits 0 to 63)
    # D5 = value (higher bits always 00h)

    send_checksum(command)
    self[:volume] = vol
  end

  # Mutes both audio/video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    mute_video(state) if layer.video? || layer.audio_video?
    mute_audio(state) if layer.audio? || layer.audio_video?
  end

  def mute_video(state : Bool)
    if state
      mute_picture
      mute_onscreen
    else
      unmute_picture
    end
  end

  def mute_audio(state : Bool)
    state ? mute_audio_cmd : unmute_audio
  end

  def switch_to(input : Input)
    logger.debug { "-- NEC LCD, requested to switch to: #{input}" }
    data = MsgType::SetParameter.build(Command::VideoInput, input.value)
    send(data, name: "input", delay: 6.seconds)
  end

  enum Audio
    HDMI
    VGA
  end

  def switch_audio(input : Audio)
    # C0 == HDMI Audio
    command = Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0xC0, input.value]
    send_checksum(command, name: "switch_audio")
  end

  def power(state : Bool)
    @power_target = state

    if state
      command = Bytes[0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
      send(command, name: "power", timeout: 15.seconds, delay: 1.second)
    else
      command = Bytes[0x02, 0x01, 0x00, 0x00, 0x00, 0x03]
      # Jump ahead of any other queued commands as they are no longer important
      send(
        command,
        name: "power",
        timeout: 60.seconds, # don't want retries occuring very fast
        delay: 30.seconds,
        clear_queue: true,
        priority: 100,
        # delay_on_receive: 200 # give it a little bit of breathing room
      )
    end
  end

  def power?(**options) : Bool
    send_checksum(COMMAND[:status_lamp], **options)
    !!self[:power]?.try(&.as_bool)
  end

  def switch_to(input : Input)
    @input_target = input
    command = Bytes[0x02, 0x03, 0x00, 0x00, 0x02, 0x01, input.value]
    send_checksum(command, name: "input")
  end

  def do_poll
    if power?(priority: 0)
      status_input(priority: 0)
      status_mute(priority: 0)
      background_black(priority: 0)
      lamp_information(priority: 0)
    end
  end

  private def check_checksum(data : Bytes)
    # Loop through the second to the third last element
    checksum = data[1..-3].reduce { |a, b| a ^ b }
    # Check the checksum equals the second last element
    logger.debug { "Error: checksum should be 0x#{checksum.to_s(16)}" } unless checksum == data[-2]
    checksum == data[-2]
  end

  private def send_checksum(command, **options)
    command = command.delete(' ').hexbytes if command.is_a?(String)
    req = Bytes.new(command.size + 1)
    req.copy_from(command)
    req[-1] = command.reduce(&.+)
    send(req, **options) { |data, task| process_response(data, task, req) }
  end

  # Values of first byte in response of successful commands
  enum Success
    Status = 0x20
    Freeze = 0x21
    Mute   = 0x22
    Lamp   = 0x23
  end

  enum Response
    Power = 0x81
    Error = 0x88
    Input = 0x03
    Lamp = 0x00
    Lamp2 = 0x01
    Mute = 0x10
    Mute1 = 0x11
    Mute2 = 0x12
    Mute3 = 0x13
    Mute4 = 0x14
    Mute5 = 0x15
  end

  private def process_response(data, task, req = nil)
    logger.debug { "NEC projector sent: 0x#{data.hexstring}" }

    if (data[0] & 0xA0) == 0xA0
      # We were changing power state at time of failure we should keep trying
      if req && [0x00, 0x01].includes?(req[1])
        # command[:delay_on_receive] = 6000
        power?
        return task.try(&.success)
      end
      # logger.warn "-- NEC projector, sent fail code for command: 0x#{byte_to_hex(req)}" if req
      # logger.warn "-- NEC projector, response was: 0x#{byte_to_hex(response)}"
      return task.try(&.abort)
    end

    # Check checksum
    unless check_checksum(data)
      # logger.warn "-- NEC projector, checksum failed for command: 0x#{byte_to_hex(req)}" if req
      return task.try(&.abort)
    end

    # Only process response if successful
    # Otherwise return success to prevent retries on commands we were not expecting
    return task.try(&.success) unless Success.from_value?(data[0]) && (resp = Response.from_value?(data[1]))

    case resp
    when .power?
    when .error?
    # when 0x85
    #   # Return if we can't work out what was requested initially
    #   return true unless req

    #   case req[-2]
    #       when 0x02
    #           return process_input_state(data, command)
    #       when 0x03
    #           process_mute_state(data, req)
    #           return true
    #   end
    when .input?
    when .lamp?, .lamp2?
    when .mute?, .mute1?, .mute2?, .mute3?, .mute4?, .mute5?
    when 0x23
      # case data[1]
      # when 0x10
      #     #
      #     # Picture, Volume, Keystone, Image adjust mode
      #     #    how to play this?
      #     #
      #     #    TODO:: process volume control
      #     #
      #     return true
      # when 0x8A
      #     process_projector_information(data, req)
      #     return true

      # when 0xB1
      #     # This is the audio switch command
      #     # TODO:: data[-2] == 0:Normal, 1:Error
      #     # If error do we retry? Or does it mean something else
      #     return true
    end

    task.try(&.success)
  end

  def received(data, task)
    process_response(data, task)
  end
end
