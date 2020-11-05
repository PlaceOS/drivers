class GlobalCache::Gc100 < PlaceOS::Driver
  # Discovery Information
  tcp_port 4999
  descriptive_name "GlobalCache IO Gateway"
  generic_name :DigitalIO

  DELIMITER = 0x0D_u8

  def on_load
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
    self[:num_relays] = 0
    self[:num_ir] = 0
    # For testing
    self[:config] = {
      relay: {
        0 => "2:1",
        1 => "2:2",
        2 => "2:3",
        3 => "3:1"
      }
    }
  end

  def connected
  end

  def disconnected
    schedule.clear
  end

  def received(data, task)
  end

  def get_devices
    do_send("getdevices")#, :max_waits => 100)
  end

  def relay(index : Int32, state : Bool, **options)
    if index < self[:num_relays].as_i
        relays = self[:config]["relay"] || self[:config]["relaysensor"]
        connector = relays[index]
        do_send("setstate,#{connector},#{state ? 1 : 0}", **options)
    else
      logger.warn { "Attempted to set relay on GlobalCache that does not exist: #{index}" }
    end
  end

  def ir(index : Int32, command : String, **options)
    do_send("sendir,1:#{index},#{command}", **options)
  end

  def set_ir(index : Int32, mode : Int32, **options)
    if index < self[:num_ir].as_i
      connector = self[:config]["ir"][index]
      do_send("set_IR,#{connector},#{mode}", **options)
    else
      logger.warn { "Attempted to set IR mode on GlobalCache that does not exist: #{index}" }
    end
  end

  private def do_send(command : String, **options)
    logger.debug { "-- GlobalCache, sending: #{command}" }
    command = "#{command}#{DELIMITER}"
    send(command, **options)
  end
end
