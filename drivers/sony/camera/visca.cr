require "placeos-driver"
require "placeos-driver/interface/camera"
require "bindata"

# Documentation: https://aca.im/driver_docs/Sony/sony_visca_over_ip.pdf
# https://aca.im/driver_docs/Aver/tr530-320-control-codes.pdf

class Sony::Camera::VISCA < PlaceOS::Driver
  include Interface::Camera

  # Discovery Information.
  generic_name :Camera
  descriptive_name "VISCA PTZ Camera"
  udp_port 52381

  default_settings({
    max_pan_tilt_speed: 0x0F,
    zoom_speed:         0x07,
    zoom_max:           0x4000,
    camera_no:          0x01,
    invert_controls:    false,
  })

  @sequence : UInt32 = 0

  @max_pan_tilt_speed : UInt8 = 0x0F_u8
  @zoom_speed : UInt8 = 0x03_u8
  @zoom_max : UInt16 = 0x4000_u16
  @camera_address : UInt8 = 0x81_u8
  @invert : Bool = false

  alias Presets = Hash(String, Tuple(UInt16, UInt16, Float64))
  @presets : Presets = {} of String => Tuple(UInt16, UInt16, Float64)
  getter zoom_raw : UInt16 = 0_u16
  @zoom_pos : Float64 = 0.0
  getter tilt_pos : UInt16 = 0_u16
  getter pan_pos : UInt16 = 0_u16

  # we want to tokenize the stream, ensure we only process a single packet at a time
  # and that we have the complete message
  def on_load
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek
      # return 0 if the message is incomplete
      next 0 if bytes.size < 4
      # return the length of the message
      IO::Memory.new(bytes[2..3]).read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i + 8
    end

    on_update
  end

  def on_update
    @presets = setting?(Presets, :camera_presets) || @presets

    @max_pan_tilt_speed = setting?(UInt8, :max_pan_tilt_speed) || 0x0F_u8
    @zoom_speed = setting?(UInt8, :zoom_speed) || 0x03_u8
    @zoom_max = setting?(UInt16, :zoom_max) || 0x4000_u16
    @camera_address = 0x80_u8 | (setting?(UInt8, :camera_no) || 1_u8)
    self[:inverted] = @invert = setting?(Bool, :invert_controls) || false
  end

  # clear the interface
  def connected
    reset_sequence_number
    send_cmd(Bytes[0x00, 0x01], name: :if_clear, priority: 98)
  end

  # ====== Camera Interface ======

  def home
    send_cmd(Bytes[0x06, 0x04], name: :pantilt)
  end

  def joystick(pan_speed : Float64, tilt_speed : Float64, index : Int32 | String = 0)
    tilt_speed = -tilt_speed if @invert

    pan_neg, pan_value, pan_zero = joyspeed(pan_speed, @max_pan_tilt_speed)
    tilt_neg, tilt_value, tilt_zero = joyspeed(tilt_speed, @max_pan_tilt_speed)

    pan_direction = pan_zero ? "03" : (pan_neg ? "01" : "02")
    tilt_direction = tilt_zero ? "03" : (tilt_neg ? "02" : "01")

    bytes = "0601#{pan_value}#{tilt_value}#{pan_direction}#{tilt_direction}"
    resp = send_cmd(bytes.hexbytes, name: :joystick)

    # query the current position after we've stopped moving
    if pan_zero && tilt_zero
      spawn(same_thread: true) do
        resp.get
        schedule.in(1.seconds) { pantilt? }
      end
    end

    resp
  end

  protected def joyspeed(speed : Float64, max)
    speed = speed.clamp(-100.0, 100.0)
    negative = speed < 0.0
    speed = speed.abs if negative

    percentage = speed / 100.0
    value = (percentage * max.to_f).round.to_u8

    bytes = Bytes[value].hexstring.rjust(2, '0')
    {negative, bytes, value.zero?}
  end

  def encode_position(value : UInt16) : String
    io = IO::Memory.new
    io.write_bytes(value, IO::ByteFormat::BigEndian)
    bytes = io.to_slice.hexstring.rjust(4, '0')
    "0#{bytes[0]}0#{bytes[1]}0#{bytes[2]}0#{bytes[3]}"
  end

  protected def decode_position(bytes : Bytes) : UInt16
    pos_data = bytes.hexstring.rjust(8, '0')
    hexstring = "#{pos_data[1]}#{pos_data[3]}#{pos_data[5]}#{pos_data[7]}"
    IO::Memory.new(hexstring.hexbytes).read_bytes(UInt16, IO::ByteFormat::BigEndian)
  end

  # moves to an absolute position
  def pantilt(pan : UInt16, tilt : UInt16, speed : UInt8)
    speed = speed.clamp(0_u8, @max_pan_tilt_speed)
    bytes = "0602#{Bytes[speed].hexstring.rjust(2, '0')}00#{encode_position(pan)}#{encode_position(tilt)}"
    send_cmd(bytes.hexbytes, name: :pantilt)
  end

  def recall(position : String, index : Int32 | String = 0)
    if pos = @presets[position]?
      pan_pos, tilt_pos, zoom_pos = pos
      pantilt(pan_pos, tilt_pos, @max_pan_tilt_speed)
      zoom_to(@zoom_pos)
    else
      raise "unknown preset #{position}"
    end
  end

  def save_position(name : String, index : Int32 | String = 0)
    @presets[name] = {@pan_pos, @tilt_pos, @zoom_pos}
    save_presets
  end

  def remove_position(name : String, index : Int32 | String = 0)
    @presets.delete(name)
    save_presets
  end

  protected def save_presets
    define_setting(:camera_presets, @presets)
    self[:camera_presets] = @presets.keys
  end

  # ====== Moveable Interface ======

  # moves at 50% of max speed
  def move(position : MoveablePosition, index : Int32 | String = 0)
    case position
    in .up?
      joystick(pan_speed: 0.0, tilt_speed: 50.0)
    in .down?
      joystick(pan_speed: 0.0, tilt_speed: -50.0)
    in .left?
      joystick(pan_speed: -50.0, tilt_speed: 0.0)
    in .right?
      joystick(pan_speed: 50.0, tilt_speed: 0.0)
    in .in?
      zoom(:in)
    in .out?
      zoom(:out)
    in .open?, .close?
      # not supported
    end
  end

  # ====== Zoomable Interface ======

  # Zooms to an absolute position
  def zoom_to(position : Float64, auto_focus : Bool = true, index : Int32 | String = 0)
    position = position.clamp(0.0, 100.0)
    percentage = position / 100.0
    zoom_value = (percentage * @zoom_max.to_f).to_u16

    bytes = "0447#{encode_position(zoom_value)}"
    send_cmd(bytes.hexbytes, name: :zoom_to)
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 0)
    speed_byte = case direction
                 in .stop?
                   schedule.in(500.milliseconds) { zoom? }
                   0x00_u8
                 in .out?
                   0x20_u8 | @zoom_speed
                 in .in?
                   0x30_u8 | @zoom_speed
                 end

    send_cmd(Bytes[0x04, 0x07, speed_byte], name: :zoom)
  end

  def zoom?
    send_inq Bytes[0x04, 0x47], name: :zoom_query, priority: 0
  end

  def pantilt?
    send_inq Bytes[0x06, 0x12], name: :pantilt_query, priority: 0
  end

  # ====== Stoppable Interface ======

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    zoom(:stop)
  end

  # =================================

  # VISCA over IP packet layout
  class Packet < BinData
    endian big

    enum Type : UInt16
      Command = 0x0100
      Inquiry = 0x0110
      Reply   = 0x0111
      # VISCA device setting
      DeviceSetting = 0x0120

      # reset: 0x01
      # error: 0x0Fyy (yy = 01 : sequence number error, 02 : message error)
      DeviceControl = 0x0200

      # Acknowledge for reset
      DeviceReply = 0x0201
    end

    enum_field UInt16, type : Type = Type::Command
    uint16 :size, value: ->{ payload.size.to_u16 }
    uint32 :sequence
    bytes :payload, length: ->{ size }
  end

  protected def send_cmd(bytes, **options)
    # VISCA message
    payload = IO::Memory.new
    payload.write Bytes[@camera_address, 0x01]
    payload.write bytes
    payload.write_byte 0xFF_u8

    # OverIP wrapper
    packet = Packet.new
    packet.type = :command
    packet.payload = payload.to_slice

    queue(**options) do |task|
      sequence = next_sequence
      packet.sequence = sequence

      transport.send(packet, task) do |data, the_task|
        # curry in the sequence we are expecting
        received(data, the_task, sequence)
      end
    end
  end

  protected def send_inq(bytes, **options)
    # VISCA message
    payload = IO::Memory.new
    payload.write Bytes[@camera_address, 0x09]
    payload.write bytes
    payload.write_byte 0xFF_u8

    # OverIP wrapper
    packet = Packet.new
    packet.type = :inquiry
    packet.payload = payload.to_slice

    queue(**options) do |task|
      sequence = next_sequence
      packet.sequence = sequence

      transport.send(packet, task) do |data, the_task|
        # curry in the sequence we are expecting
        received(data, the_task, sequence)
      end
    end
  end

  protected def next_sequence : UInt32
    # we want to ignore overflows
    @sequence = @sequence &+ 1_u32
  end

  protected def reset_sequence_number(directly : Bool = false)
    packet = Packet.new
    packet.type = :device_control
    packet.sequence = @sequence = 0_u32
    packet.payload = Bytes[0x01_u8]

    return transport.send(packet) if directly
    queue(name: :reset_sequence_number, priority: 99) do |task|
      transport.send(packet, task) do |data|
        # curry in the sequence we are expecting
        received(data, task, @sequence)
      end
    end
  end

  # process incoming data, tokenised so we know each data packet is exactly one message
  def received(data, task, sequence : UInt32? = nil) : Nil
    logger.debug { "Camera sent: 0x#{data.hexstring}" }

    # Was this expected data? Should have a sequence curried in
    if sequence.nil?
      logger.info { "unexpected packet received, ignoring as no sequence pending" }
      return
    end

    io = IO::Memory.new(data)
    packet = io.read_bytes(Packet)
    payload = packet.payload

    # process any errors
    case packet.type
    when .device_control?
      case payload[-1]
      when 1_u8
        # Abnormality in the sequence number, let's reset it
        # then we can retry the task in the ack
        reset_sequence_number(directly: true)
        logger.info { "sequence number error, resetting sequence" }
      when 2_u8
        # Abnormality in the message
        task.try(&.abort("bad request"))
      end
      return
    when .device_reply?
      if task && task.name == "reset_sequence_number"
        task.success
      else
        task.try(&.retry("sequence number reset, retrying task"))
      end
      return
    when .reply?
      # ensure it's for the current request
      if sequence != packet.sequence
        logger.info { "unexpected sequence number, ignoring" }
        return
      end
    else
      logger.info { "unexpected packet type #{packet.type}, ignoring" }
      return
    end

    # Check response
    check_command = payload[1] & 0xF0_u8
    case check_command
    when 0x40_u8
      # ignore accepted message, we are interested in the completion message
      logger.debug { "ignoring command accepted message" }
      return
    when 0x50_u8
      logger.debug { "command complete message" }
      # command execution completed successfully
      # fall through to processing
    when 0x60_u8
      # an error occured!
      case payload[2]
      when 0x02_u8
        task.try(&.abort("syntax error in request"))
      when 0x03_u8
        # command buffer is full, lets retry the request
        schedule.in(50.milliseconds) { task.try &.retry("camera busy") }
      when 0x04_u8
        task.try(&.abort("request was cancelled by the user"))
      when 0x05_u8
        # attempt to cancel a command that might have already executed
        task.try(&.success)
      when 0x41_u8
        # command can't be executed with the current camera state
        task.try(&.abort("request could not be performed"))
      end
      return
    end

    # process the packet!
    case task.try &.name
    when "zoom_query"
      @zoom_raw = zoom_value = decode_position(payload[2..5])
      self[:zoom] = @zoom_pos = zoom_value.to_f * (100.0 / @zoom_max.to_f)
    when "pantilt_query"
      @pan_pos = decode_position(payload[2..5])
      @tilt_pos = decode_position(payload[6..9])
    when "zoom_to"
      zoom?
    when "pantilt"
      pantilt?
    end

    task.try &.success
  end
end
