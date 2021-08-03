require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/zoomable"

# Documentation: https://aca.im/driver_docs/Lumens/DC193-Protocol.pdf
# RS232 controlled device

class Lumens::DC193 < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Zoomable

  # Discovery Information
  descriptive_name "Lumens DC 193 Document Camera"
  generic_name :DocCam

  # Global Cache Port
  tcp_port 4999

  def on_load
    # Communication settings
    queue.delay = 100.milliseconds
    transport.tokenizer = Tokenizer.new(6)

    # Ensure range is roughly accurate
    @zoom_range = 0..@zoom_max
  end

  def connected
    schedule.every(50.seconds) { query_status }
    query_status
  end

  def disconnected
    schedule.clear
  end

  def query_status
    # Responses are JSON encoded
    if power?.get == "true"
      lamp?
      zoom?
      frozen?
      max_zoom?
      picture_mode?
    end
  end

  def power(state : Bool)
    state = state ? 0x01_u8 : 0x00_u8
    send Bytes[0xA0, 0xB0, state, 0x00, 0x00, 0xAF], name: :power
    power?
  end

  def power?
    # item 58 call system status
    send Bytes[0xA0, 0xB7, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def lamp(state : Bool, head_led : Bool = false)
    return false if @frozen

    lamps = if state && head_led
              1_u8
            elsif state
              2_u8
            elsif head_led
              3_u8
            else
              0_u8
            end

    send Bytes[0xA0, 0xC1, lamps, 0x00, 0x00, 0xAF], name: :lamp
  end

  def lamp?
    send Bytes[0xA0, 0x50, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def zoom_to(position : Int32, auto_focus : Bool = true, index : Int32 | String = 0)
    return false if @frozen

    position = (position < 0 ? 0 : @zoom_max) unless @zoom_range.includes?(position)
    low = (position & 0xFF).to_u8
    high = ((position >> 8) & 0xFF).to_u8
    auto_focus = auto_focus ? 0x1F_u8 : 0x13_u8
    send Bytes[0xA0, auto_focus, low, high, 0x00, 0xAF], name: :zoom_to
  end

  def zoom(direction : ZoomDirection, index : Int32 | String = 1)
    return false if @frozen

    case direction
    when ZoomDirection::Stop
      send Bytes[0xA0, 0x10, 0x00, 0x00, 0x00, 0xAF]
      # Ensures this request is at the normal priority and ordering is preserved
      zoom?(priority: queue.priority)
      # This prevents the auto-focus if someone starts zooming again
      auto_focus(name: "zoom")
    when ZoomDirection::In
      send Bytes[0xA0, 0x11, 0x00, 0x00, 0x00, 0xAF], name: :zoom
    when ZoomDirection::Out
      send Bytes[0xA0, 0x11, 0x01, 0x00, 0x00, 0xAF], name: :zoom
    end
  end

  def auto_focus(name : String = "auto_focus")
    return false if @frozen

    send Bytes[0xA0, 0xA3, 0x01, 0x00, 0x00, 0xAF], name: name
  end

  def zoom?(priority : Int32 = 0)
    send Bytes[0xA0, 0x60, 0x00, 0x00, 0x00, 0xAF], priority: priority
  end

  def freeze(state : Bool)
    state = state ? 1_u8 : 0_u8
    send Bytes[0xA0, 0x2C, state, 0x00, 0x00, 0xAF], name: :freeze
  end

  def frozen?
    send Bytes[0xA0, 0x78, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def picture_mode(state : String)
    return false if @frozen

    mode = case state.downcase
           when "photo"
             0x00_u8
           when "text"
             0x01_u8
           when "greyscale", "grayscale"
             0x02_u8
           else
             raise ArgumentError.new("unknown picture mode #{state}")
           end
    send Bytes[0xA0, 0xA7, mode, 0x00, 0x00, 0xAF], name: :picture_mode
  end

  def picture_mode?
    send Bytes[0xA0, 0x51, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def max_zoom?
    send Bytes[0xA0, 0x8A, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  @[Flags]
  enum Status
    Error
    Ignored
    Reserved1
    Reserved2
    Focusing
    Zooming
    Iris
    Reserved3
  end

  COMMANDS = {
    0xC1_u8 => :lamp,
    0xB0_u8 => :power,
    0xB7_u8 => :power_staus,
    0xA7_u8 => :picture_mode,
    0xA3_u8 => :auto_focus,
    0x8A_u8 => :max_zoom,
    0x78_u8 => :frozen_status,
    0x60_u8 => :zoom_staus,
    0x51_u8 => :picture_mode_staus,
    0x50_u8 => :lamp_staus,
    0x2C_u8 => :freeze,
    0x1F_u8 => :zoom_direct_auto_focus,
    0x13_u8 => :zoom_direct,
    0x11_u8 => :zoom,
    0x10_u8 => :zoom_stop,
  }

  @ready : Bool = true
  @power : Bool = false
  @zoom_max : Int32 = 864
  @lamp : Bool = false
  @head_led : Bool = false
  @frozen : Bool = false

  PICTURE_MODES = {:photo, :test, :greyscale}

  def received(data, task)
    logger.debug { "Lumens sent: #{data.hexstring}" }

    status = Status.from_value(data[4].to_i)
    self[:zooming] = status.zooming?
    self[:focusing] = status.focusing?
    self[:iris_adjusting] = status.iris?

    return task.try &.abort("bad request") if status.error?
    return task.try &.retry("device busy") if status.ignored?

    result = case COMMANDS[data[1]]?
             when :power
               data[2] == 0x01_u8
             when :power_staus
               @ready = data[2] == 0x01_u8
               @power = data[3] == 0x01_u8
               logger.debug { "System power: #{@power}, ready: #{@ready}" }
               self[:ready] = @ready
               self[:power] = @power
             when :max_zoom
               @zoom_max = data[2].to_i + (data[3].to_i << 8)
               @zoom_range = 0..@zoom_max
               self[:zoom_range] = {min: 0, max: @zoom_max}
             when :frozen_status, :freeze
               self[:frozen] = @frozen = data[2] == 1_u8
             when :zoom_staus, :zoom_direct_auto_focus, :zoom_direct
               @zoom = data[2].to_i + (data[3].to_i << 8)
               self[:zoom] = @zoom
             when :picture_mode_staus, :picture_mode
               self[:picture_mode] = PICTURE_MODES[data[2].to_i]
             when :lamp_staus, :lamp
               case data[2]
               when 0_u8
                 @head_led = @lamp = false
               when 1_u8
                 @head_led = @lamp = true
               when 2_u8
                 @head_led = false
                 @lamp = true
               when 3_u8
                 @head_led = true
                 @lamp = false
               end
               self[:head_led] = @head_led
               self[:lamp] = @lamp
             when :auto_focus
               # Can ignore this response
             else
               error = "Unknown command #{data[1]}"
               logger.debug { error }
               return task.try &.abort(error)
             end

    task.try &.success(result)
  end
end
