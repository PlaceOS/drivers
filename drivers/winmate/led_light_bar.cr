require "placeos-driver"

# Documentation: https://aca.im/driver_docs/Winmate/LED%20Light%20Bar%20SDK.pdf

class Winmate::LedLightBar < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Winmate PC - LED Light Bar"
  generic_name :StatusLight
  tcp_port 8000

  def on_load
    queue.delay = 100.milliseconds
    on_update
  end

  DEFAULT_COLOURS = {
    "red" => {
      red:   255_u8,
      green: 0_u8,
      blue:  0_u8,
    },
    "green" => {
      red:   0_u8,
      green: 255_u8,
      blue:  0_u8,
    },
    "blue" => {
      red:   0_u8,
      green: 0_u8,
      blue:  255_u8,
    },
    "orange" => {
      red:   200_u8,
      green: 0_u8,
      blue:  0_u8,
    },
    "off" => {
      red:   0_u8,
      green: 0_u8,
      blue:  0_u8,
    },
  }

  alias Colours = Hash(String, NamedTuple(red: UInt8, green: UInt8, blue: UInt8))

  @colours : Colours = Colours.new

  def on_update
    colours = setting?(Colours, :colours) || Colours.new
    @colours = colours.merge(DEFAULT_COLOURS)
  end

  def connected
    @buffer = String.new

    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek # for demonstration purposes
      bytes[0].to_i
    end

    do_poll
    schedule.every(50.seconds) do
      logger.debug { "-- Polling Winmate LED" }
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def colour(colour : String)
    colours = @colours[colour]
    self[:colour_name] = colour
    colours.each do |component, intensity|
      led = Led.parse(component.to_s)
      set led, intensity
    end
  end

  enum Led
    Red
    Green
    Blue
  end

  COLOURS = {
    Led::Red   => 0x10_u8,
    Led::Green => 0x11_u8,
    Led::Blue  => 0x12_u8,
  }

  COLOUR_LOOKUP = {
    0x10 => Led::Red,
    0x11 => Led::Green,
    0x12 => Led::Blue,
  }

  COMMANDS = {
    set: 0x61_u8,
    get: 0x60_u8,
  }

  def query(led : Led, **options)
    do_send(**options.merge({
      command: :get,
      colour:  led,
    }))
  end

  def set(led : Led, value : UInt8, **options)
    self[led.to_s.downcase] = value

    do_send(**options.merge({
      command: :set,
      colour:  led,
      value:   value,
    }))
  end

  def do_poll
    query(:red, priority: 0)
    query(:green, priority: 0)
    query(:blue, priority: 0)
  end

  def received(bytes, task)
    logger.debug { "received: #{bytes.hexstring}" }

    unless check_checksum(bytes)
      logger.warn { "Error processing response. Possibly incorrect baud rate configured" }
      return task.try(&.abort)
    end

    # first byte is the message length, so we can ignore that
    indicator = bytes[1]
    colour = COLOUR_LOOKUP[indicator]?
    if colour
      self[colour.to_s.downcase] = bytes[2]
      task.try(&.success(bytes[2]))
    else
      return task.try(&.abort) unless indicator == 0x0C
      task.try(&.success)
    end
  end

  # 2’s complement, &+ operators ignore overflows
  protected def build_checksum(data : Array(UInt8))
    result = data.reduce(0_u8) { |sum, byte| sum &+= byte }
    ((~(result & 0xFF_u8)) &+ 1_u8)
  end

  protected def check_checksum(data : Bytes)
    check = data.to_a
    result = check.pop
    result == build_checksum(check)
  end

  protected def do_send(command : Symbol, colour : Led, value : UInt8? = nil, **options)
    cmd = COMMANDS[command]
    led = COLOURS[colour]

    # Build core request
    req = [cmd, led]
    req << value if value

    # Add length indicator
    len = (req.size + 2).to_u8
    req.unshift len

    # Calculate checksum
    req << build_checksum(req)
    bytes = Slice.new(req.to_unsafe, req.size)
    logger.debug { "requesting #{bytes}" }

    options = options.merge({
      name: "#{command}_#{colour}_#{!!value}",
    })

    send(bytes, **options)
  end
end
