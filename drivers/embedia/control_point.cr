require "placeos-driver"

# Documentation: https://aca.im/driver_docs/Embedia/Embedia%20Control%20Point%20rev2013.pdf
# RS232 Gateway. Baud Rate 9600,8,N,1

# this is a good example of communicating with a binary protocol
# although this particular device uses hex encoded streams
class Embedia::ControlPoint < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Embedia Control Point Blinds"
  generic_name :Blinds
  description %(simple driver to control embedia blinds, doesn't expose any state)

  # Global Cache Port
  tcp_port 4999

  def on_load
    # this device doesn't respond when we make requests to it
    queue.wait = false

    # the documentation specifies a delay needs to occur between sends
    # to allow the device some time to process requests
    queue.delay = 200.milliseconds

    # all messages from the device are terminated so we can tokenize the
    # IO stream
    transport.tokenizer = Tokenizer.new("\r\n")
  end

  def connected
    schedule.every(1.minute) do
      logger.debug { "Maintaining connection" }
      query_sensor 0
    end
  end

  def disconnected
    schedule.clear
  end

  COMMANDS = {
    stop:                   0x28,
    down:                   0x4e, # Also extend
    up:                     0x4b, # Also retract
    next_extent_preset:     0x4f,
    previous_extent_preset: 0x50,

    close:                0x16,
    open:                 0x1a,
    next_tilt_preset:     0x07,
    previous_tilt_preset: 0x04,

    clear_override: 0x4c,
  }

  {% begin %}
    {% for command, value in COMMANDS %}
      def {{command.id}}(address : UInt8, **options)
        do_send Bytes[address, 0x06, 0, 1, 0, {{value}}], **options
      end
    {% end %}
  {% end %}

  def extent_preset(address : UInt8, number : UInt8, **options)
    num = 0x1D + number.clamp(1, 10)
    do_send Bytes[address, 0x06, 0, 1, 0, num], **options, name: "extent_preset#{address}"
  end

  def tilt_preset(address : UInt8, number : UInt8, **options)
    num = 0x39 + number.clamp(1, 10)
    do_send Bytes[address, 0x06, 0, 1, 0, num], **options, name: "tilt_preset#{address}"
  end

  def query_sensor(address : UInt8, **options)
    do_send Bytes[address, 0x03, 0, 1, 0, 1], **options
  end

  protected def do_send(data : Bytes, **options)
    sending = data.hexstring.upcase
    logger.debug { "sending :#{sending}--" }
    send ":#{sending}--\r\n", **options
  end

  # as we've configured the tokenizer we know that for every invokation of this function
  # will contain exactly one message from the device
  def received(bytes, task)
    logger.debug {
      # remove the newline chars
      raw_data = String.new(bytes).strip

      # strip the padding ':' and The LRC checksum
      data = raw_data[1..-3].hexbytes
      address = data[0]
      func = data[1]

      case func
      when 3 # Sensor level
        "sensor response #{raw_data} on address 0x#{address.to_s(16)}"
      else
        "sent #{raw_data} on address 0x#{address.to_s(16)}"
      end
    }

    # as this device is not waiting for responses task will always be nil
    task.try &.success
  end
end
