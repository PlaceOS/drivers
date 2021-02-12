# Documentation: https://aca.im/driver_docs/Sony/Sony_Q004_R1_protocol.pdf
# also https://aca.im/driver_docs/Sony/TCP_CMDs.pdf

class Sony::Projector::SerialControl < PlaceOS::Driver
  descriptive_name "Sony Projector (RS232 Control)"
  generic_name :Display

  def on_load
  end

  def connected
    # schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    if state
      # Need to send twice in case of deep sleep
      do_send("set", Command::PowerOn, name: :power, wait: false)
      do_send("set", Command::PowerOn, name: :power, delay: 3.seconds, wait: false)
      logger.debug { "requested to power on" }
    else
      do_send("set", Command::PowerOff, name: :power, delay: 3.seconds, wait: false)
      logger.debug { "requested to power off" }
    end
    # Request status update
    power?(priority: 50)
  end

  def power?(priority : Int32 = 0, **options)
    do_send("get", Command::PowerStatus, **options, priority: priority)
  end

  enum Input
    HDMI = 0x0003 # same as InputB
    InputA = 0x0002
    InputB = 0x0003
    InputC = 0x0004
    InputD = 0x0005
    USB =  0x0006 # USB type B
    Network = 0x0007 # network

    def to_bytes : Bytes
      Bytes[self.value >> 8, self.value & 0xFF]
    end

    def self.from_bytes(b : Bytes)
      Input.from_value((b[0].to_u16 << 8) + b[1])
    end
  end

  def switch_to(input : Input)
    do_send("set", Command::Input, input.to_bytes, delay_on_receive: 500.milliseconds)
    logger.debug { "requested to switch to: #{input}" }

    input?
  end

  def input?
    do_send("get", Command::Input, priority: 0)
  end

  def lamp_time?
    do_send("get", :lamp_timer, priority: 0)
  end

  enum Command
    PowerOn     = 0x172E
    PowerOff    = 0x172F
    Input       = 0x0001
    Mute        = 0x0030
    ErrorStatus = 0x0101
    PowerStatus = 0x0102
    Contrast    = 0x0010
    Brightness  = 0x0011
    Color       = 0x0012
    Hue         = 0x0013
    Sharpness   = 0x0014
    LampTimer   = 0x0113

    def to_bytes : Bytes
      Bytes[self.value >> 8, self.value & 0xFF]
    end

    def self.from_bytes(b : Bytes)
      Command.from_value((b[0].to_u16 << 8) + b[1])
    end
  end

  private def do_send(getset : String, command : Command, param : Bytes = Bytes.new(2), **options)
    # if getset == "get"
    #     options[:name] = :"#{command}_req" if options[:name].nil?
    #     type = [0x01]
    # else
    #     options[:name] = command if options[:name].nil?
    #     type = [0x00]
    # end

    # param.unshift(0) if param.length < 2

    # # Build the request
    # cmd = cmd + type + param
    # cmd << checksum(cmd)
    # cmd << 0x9A
    # cmd.unshift(0xA9)

    # send(cmd, options)
  end

  def received(data, task)
    task.try &.success
  end
end
