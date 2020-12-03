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

  def on_load
    # Communication settings
    queue.delay = 100.milliseconds
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
    schedule.every(50.seconds, true) { do_poll }
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
    mute_picture:     Bytes[0x02, 0x10, 0x00, 0x00, 0x00, 0x12],
    unmute_picture:   Bytes[0x02, 0x11, 0x00, 0x00, 0x00, 0x13],
    mute_audio_cmd:   Bytes[0x02, 0x12, 0x00, 0x00, 0x00, 0x14],
    unmute_audio_cmd: Bytes[0x02, 0x13, 0x00, 0x00, 0x00, 0x15],
    mute_onscreen:    Bytes[0x02, 0x14, 0x00, 0x00, 0x00, 0x16],
    unmute_onscreen:  Bytes[0x02, 0x15, 0x00, 0x00, 0x00, 0x17],

    freeze_picture:   Bytes[0x01, 0x98, 0x00, 0x00, 0x01, 0x01],
    unfreeze_picture: Bytes[0x01, 0x98, 0x00, 0x00, 0x01, 0x02],

    lamp?:  Bytes[0x00, 0x81, 0x00, 0x00, 0x00, 0x81], # Running sense (ret 81)
    input?: Bytes[0x00, 0x85, 0x00, 0x00, 0x01, 0x02], # Input status (ret 85)
    mute?:  Bytes[0x00, 0x85, 0x00, 0x00, 0x01, 0x03], # MUTE STATUS REQUEST (Check 10H on byte 5)
    error?: Bytes[0x00, 0x88, 0x00, 0x00, 0x00, 0x88], # ERROR STATUS REQUEST (ret 88)
    model?: Bytes[0x00, 0x85, 0x00, 0x00, 0x01, 0x04], # Request model name (both of these are related)

    # lamp hours / remaining info
    lamp_info:      Bytes[0x03, 0x8A, 0x00, 0x00, 0x00, 0x8D], # LAMP INFORMATION REQUEST
    filter_info:    Bytes[0x03, 0x8A, 0x00, 0x00, 0x00, 0x8D],
    projector_info: Bytes[0x03, 0x8A, 0x00, 0x00, 0x00, 0x8D],

    background_black: Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0x0B, 0x01], # set mute to be a black screen
    background_blue:  Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0x0B, 0x00], # set mute to be a blue screen
    background_logo:  Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0x0B, 0x02], # set mute to be the company logo
  }

  {% for name, data in COMMAND %}
    def {{name.id}}(**options)
      pp "sending " + {{name.id.stringify}} + " with"
      do_send(COMMAND[{{name.id.stringify}}], **options, name: {{name.id.stringify}})
    end
  {% end %}

  def volume(vol : Int32)
    vol = vol.clamp(@volume_min, @volume_max)
    # volume base command                           D1    D2    D3   D4    D5
    command = Bytes[0x03, 0x10, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00, vol, 0x00]
    # D3 = 00 (absolute vol) or 01 (relative vol)
    # D4 = value (lower bits 0 to 63)
    # D5 = value (higher bits always 00h)

    do_send(command)
    self[:volume] = vol # TODO: remove
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
    state ? mute_audio_cmd : unmute_audio_cmd
  end

  def switch_to(input : Input)
    logger.debug { "-- NEC projector, requested to switch to: #{input}" }
    @input_target = input
    command = Bytes[0x02, 0x03, 0x00, 0x00, 0x02, 0x01, input.value]
    do_send(command, name: "input")
  end

  enum Audio
    HDMI
    VGA
  end

  def switch_audio(input : Audio)
    # C0 == HDMI Audio
    command = Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0xC0, input.value]
    do_send(command, name: "switch_audio")
  end

  def power(state : Bool)
    @power_target = state

    if state
      command = Bytes[0x02, 0x00, 0x00, 0x00, 0x00]
      do_send(command, name: "power", timeout: 15.seconds, delay: 1.second)
    else
      command = Bytes[0x02, 0x01, 0x00, 0x00, 0x00]
      # Jump ahead of any other queued commands as they are no longer important
      do_send(
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
    do_send(COMMAND[:lamp?], **options, name: "power?").get
    !!self[:power]?.try(&.as_bool)
  end

  def switch_to(input : Input)
    @input_target = input
    command = Bytes[0x02, 0x03, 0x00, 0x00, 0x02, 0x01, input.value]
    do_send(command, name: "input")
  end

  def do_poll
    if power?(priority: 0)
      mute?(priority: 0)
      background_black(priority: 0)
      lamp_info(priority: 0)
    end
  end

  private def checksum_valid?(data : Bytes)
    checksum = data[0..-2].sum(0) & 0xFF
    logger.debug { "Error: checksum should be 0x#{checksum.to_s(16, true)}" } unless result = checksum == data[-1]
    result
  end

  private def do_send(command, **options)
    command = command.delete(' ').hexbytes if command.is_a?(String)
    req = Bytes.new(command.size + 1)
    req.copy_from(command)
    req[-1] = (command.sum(0) & 0xFF).to_u8
    pp "Nec proj sending 0x#{req.hexstring}"
    logger.debug { "Nec proj sending 0x#{req.hexstring}" }
    send(req, **options) { |data, task| process_response(data, task, req) }
  end

  # TODO: add responses for freeze commands
  enum Response : UInt16
    Power               = 8321 # [0x20,0x81]
    InputOrMuteQuery    = 8325 # [0x20,0x85]
    Error               = 8328 # [0x20,0x88]
    InputSwitch         = 8707 # [0x22,0x03]
    Lamp                = 8704 # [0x22,0x00]
    Lamp2               = 8705 # [0x22,0x01]
    Mute                = 8721 # [0x22,0x11]
    Mute2               = 8722 # [0x22,0x12]
    Mute3               = 8723 # [0x22,0x13]
    Mute4               = 8724 # [0x22,0x14]
    Mute5               = 8725 # [0x22,0x15]
    VolumeOrImageAdjust = 8721 # [0x23,0x10]
    Info                = 9098 # [0x23,0x8A]
    AudioSwitch         = 9137 # [0x23,0xB1]

    def self.from_bytes(response)
      value = IO::Memory.new(response[0..1]).read_bytes(UInt16, IO::ByteFormat::BigEndian)
      Response.from_value?(value)
    end
  end

  private def process_response(data, task, req = nil)
    pp "NEC projector sent: 0x#{data.hexstring}"
    logger.debug { "NEC projector sent: 0x#{data.hexstring}" }

    # Command failed
    if (data[0] & 0xA0) == 0xA0
      # We were changing power state at time of failure we should keep trying
      if req && (0..1).includes?(req[1])
        # command[:delay_on_receive] = 6000
        power?
        return task.try(&.success)
      end
      return task.try(&.abort("-- NEC projector, sent fail code for command: 0x#{req.try(&.hexstring) || "unknown"}"))
    end

    # Verify checksum
    unless checksum_valid?(data)
      return task.try(&.abort("-- NEC projector, checksum failed for command: 0x#{req.try(&.hexstring) || "unknown"}"))
    end

    # Only process response if successful
    # Otherwise return success to prevent retries on commands we were not expecting
    unless resp = Response.from_bytes(data)
      return task.try(&.success("-- NEC projector, no status updates defined for response for command: 0x#{req.try(&.hexstring) || "unknown"}"))
    end

    case resp
    when .power?
      process_power_status(data, task)
    when .input_or_mute_query?
      # Return if we can't work out what was requested initially
      return task.try(&.success) unless req && (2..3).includes?(req[-2])
      process_input_state(data, task) if req[-2] == 2
      process_mute_state(data, task) if req[-2] == 3
    when .error?
      process_error_status(data, task)
    when .input_switch?
      process_input_switch(data, task, req)
    when .lamp?, .lamp2?
      process_lamp_command(data, task, req)
    when .mute?, .mute2?, .mute3?, .mute4?, .mute5?
      mute? # update mute status
      task.try(&.success)
    when .volume_or_image_adjust?
      # TODO:: process volume control
      task.try(&.success)
    when .info?
      process_projector_info(data, task)
    when .audio_switch?
      # This is the audio switch command
      # TODO:: data[-2] == 0:Normal, 1:Error
      # If error do we retry? Or does it mean something else
      task.try(&.success)
    end
  end

  def received(data, task)
    process_response(data, task)
  end

  # Process the lamp status response
  # Intimately entwined with the power power command
  # (as we need to control ensure we are in the correct target state)
  private def process_power_status(data, task)
    logger.debug { "-- NEC projector sent a response to a power status command" }

    self[:power] = (data[-2] & 0b10) > 0

    # Projector cooling || power on off processing
    if (data[-2] & 0b100000) > 0 || (data[-2] & 0b10000000) > 0
      if @power_target
        self[:cooling] = false
        self[:warming] = true
        logger.debug { "power warming..." }
      else
        self[:warming] = false
        self[:cooling] = true
        logger.debug { "power cooling..." }
      end

      schedule.in(3.seconds) { power? }
    # Signal processing
    elsif (data[-2] & 0b1000000) > 0
      schedule.in(3.seconds) { power? }
    else # We are in a stable state!
      if power_target = @power_target
        if self[:power] == power_target
          @power_target = nil
        else # We are in an undesirable state and will try to correct it
          logger.debug { "NEC projector in an undesirable power state... (Correcting)" }
          power(power_target)
        end
      else
        logger.debug { "NEC projector is in a good power state..." }
        self[:warming] = false
        self[:cooling] = false
        # TODO
        # Ensure the input is in the correct state unless the lamp is off
        input? if self[:power].as_bool # Calls status mute
      end
    end

    logger.debug { "Current state {power: #{self[:power]}, warming: #{self[:warming]}, cooling: #{self[:cooling]}}" }
    task.try(&.success)
  end

  # NEC has different values for the input status when compared to input selection
  INPUT_MAP = {
    0x01 => {
      0x01 => Input::VGA,
      0x02 => Input::Composite,
      0x03 => Input::SVideo,
      0x06 => Input::HDMI,
      0x07 => Input::Viewer,
      0x21 => Input::HDMI,
      0x22 => Input::DisplayPort,
    },
    0x02 => {
      0x01 => Input::RGBHV,
      0x04 => Input::Component2,
      0x06 => Input::HDMI2,
      0x07 => Input::LAN,
      0x21 => Input::HDMI2,
    },
    0x03 => {
      0x04 => Input::Component,
    },
  }

  private def process_input_state(data, task)
    return task.try(&.success) unless self[:power]?.try(&.as_bool) && (first = INPUT_MAP[data[-15]])

    logger.debug { "-- NEC projector sent a response to an input state command" }

    self[:input] = current_input = first[data[-14]] || "unknown"
    if data[-17] == 0x01
      # TODO
      # command[:delay_on_receive] = 3000 # still processing signal
      input?
    else # TODO: figure out if this is needed from old ruby driver
      # mute? # get mute status one signal has settled
    end

    pp "The input selected was: #{current_input}"
    logger.debug { "The input selected was: #{current_input}" }

    # Notify of bad input selection for debugging
    # We ensure at the very least power state and input are always correct
    if (input_target = @input_target)
      # If we have reached the input_target, clear @input_target so input can be set again
      if current_input == input_target
        @input_target = nil
      else
        logger.debug { "-- NEC input state may not be correct, desired: #{input_target} current: #{current_input}" }
        switch_to(input_target)
      end
    end

    task.try(&.success)
  end

  private def process_mute_state(data, task)
    logger.debug { "-- NEC projector responded to mute state command" }
    self[:mute] = self[:picture_mute] = data[-17] == 0x01
    self[:audio_mute] = data[-16] == 0x01
    self[:onscreen_mute] = data[-15] == 0x01
    task.try(&.success)
  end

  private def process_input_switch(data, task, req)
    logger.debug { "-- NEC projector responded to switch input command" }
    if data[-2] != 0xFF
      input? # Double check with a status update
      return task.try(&.success)
    end
    task.try(&.retry("-- NEC projector failed to switch input with command: #{req.try(&.hexstring) || "unknown"}"))
  end

  private def process_lamp_command(data, task, req)
    logger.debug { "-- NEC projector sent a response to a power command" }
    # Ensure a change of power state was the last command sent
    if req && (0..1).includes?(req[1])
      power? # Queues the status power command
    end
    task.try(&.success)
  end

  # Provide all the error info required
  ERROR_CODES = [{
           0b1 => "Lamp cover error",
          0b10 => "Temperature error (Bimetal)",
       # 0b100 => not used
        0b1000 => "Fan Error",
       0b10000 => "Fan Error",
      0b100000 => "Power Error",
     0b1000000 => "Lamp Error",
    0b10000000 => "Lamp has reached its end of life",
  }, {
      0b1 => "Lamp has been used beyond its limit",
     0b10 => "Formatter error",
    0b100 => "Lamp no.2 Error",
  }, {
         # 0b1 => "not used"
          0b10 => "FPGA error",
         0b100 => "Temperature error (Sensor)",
        0b1000 => "Lamp housing error",
       0b10000 => "Lamp data error",
      0b100000 => "Mirror cover error",
     0b1000000 => "Lamp no.2 has reached its end of life",
    0b10000000 => "Lamp no.2 has been used beyond its limit",
  }, {
       0b1 => "Lamp no.2 housing error",
      0b10 => "Lamp no.2 data error",
     0b100 => "High temperature due to dust pile-up",
    0b1000 => "A foreign object sensor error",
  }]

  private def process_error_status(data, task)
    logger.debug { "-- NEC projector sent a response to an error status command" }
    errors = [] of String
    # Run through each byte
    data[5..8].each_with_index do |byte, byte_no|
      # If there is an error
      if byte > 0
        # Go through each individual bit
        ERROR_CODES[byte_no].each_key do |bit_check|
          # Add the error if the bit corresponding to an error is set
          errors.push(ERROR_CODES[byte_no][bit_check]) if (bit_check & byte) > 0
        end
      end
    end
    self[:error] = errors
    task.try(&.success)
  end

  private def process_projector_info(data, task)
    logger.debug { "-- NEC projector sent a response to a projector info command" }
    # Calculate lamp/filter usage in seconds
    lamp = data[87..90].each_with_index.sum { |byte, index| byte.to_i << (index * 8) }
    filter = data[91..94].each_with_index.sum { |byte, index| byte.to_i << (index * 8) }
    # Convert seconds to hours
    self[:lamp_usage] = lamp / 3600
    self[:filter_usage] = filter / 3600
    logger.debug { "lamp usage is #{self[:lamp_usage]} hours, filter usage is #{self[:filter_usage]} hours" }
    task.try(&.success)
  end
end
