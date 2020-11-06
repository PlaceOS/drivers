class GlobalCache::Gc100 < PlaceOS::Driver
  # Discovery Information
  tcp_port 4999
  descriptive_name "GlobalCache IO Gateway"
  generic_name :DigitalIO

  DELIMITER = "\r"

  # @relay_config maps the GC100 into a linear set of ir and relays so models can be swapped in and out
  # E.g. @relay_config = {"relay" => {0 => "2:1",1 => "2:2",2 => "2:3",3 => "3:1"}}
  @relay_config : Hash(String, Hash(Int32, String)) = {} of String => Hash(Int32, String)
  @port_config : Hash(String, Tuple(String, Int32)) = {} of String => Tuple(String, Int32)

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
    self[:num_relays] = 0
    self[:num_ir] = 0
  end

  def connected
    @relay_config = {} of String => Hash(Int32, String)
    @port_config = {} of String => Tuple(String, Int32)
    self[:config_indexed] = false

    schedule.every(10.seconds, true) do
      logger.debug { "-- Polling GC100" }
      get_devices unless self[:config_indexed].as_bool

      # Low priority sent to maintain the connection
      do_send("get_NET,0:1", priority: 0)
    end
  end

  def disconnected
    schedule.clear
  end

  def get_devices
    do_send("getdevices") # , :max_waits => 100)
  end

  def relay(index : Int32, state : Bool, **options)
    if index < self[:num_relays].as_i
      relays = (self[:relay_config]["relay"]? || self[:relay_config]["relaysensor"]?).not_nil!.as_h
      logger.debug { "relays = #{relays}" }
      connector = relays[index.to_s]
      do_send("setstate,#{connector},#{state ? 1 : 0}", **options)
    else
      logger.warn { "Attempted to set relay on GlobalCache that does not exist: #{index}" }
    end
  end

  def ir(index : Int32, command : String, **options)
    do_send("sendir,1:#{index},#{command}", **options)
  end

  enum IrMode
    IR
    SENSOR
    SENSOR_NOTIFY
    IR_NOCARRIER
  end
  def set_ir(index : Int32, mode : IrMode, **options)
    if index < self[:num_ir].as_i
      connector = self[:relay_config]["ir"][index.to_s]
      do_send("set_IR,#{connector},#{mode}", **options)
    else
      logger.warn { "Attempted to set IR mode on GlobalCache that does not exist: #{index}" }
    end
  end

  def relay_status?(index : Int32, **options)
    if index < self[:num_relays].as_i
      connector = self[:relay_config]["relay"][index.to_s]
      do_send("getstate,#{connector}", **options)
    else
      logger.warn { "Attempted to check IO on GlobalCache that does not exist: #{index}" }
    end
  end

  def ir_status?(index : Int32, **options)
    if index < self[:num_ir].as_i
      connector = self[:relay_config]["ir"][index.to_s]
      do_send("getstate,#{connector}", **options)
    else
      logger.warn { "Attempted to check IO on GlobalCache that does not exist: #{index}" }
    end
  end

  def received(data, task)
    # Remove the delimiter
    data = String.new(data[0..-2])
    logger.debug { "GlobalCache sent #{data}" }
    data = data.split(',')
    task_name = task.try &.name || "unknown"

    case data[0]
    when "state", "statechange"
      type, index = self[:port_config][data[1]]
      self["#{type}#{index}"] = data[2] == "1" # Is relay index on?
    when "device"
      address = data[1]
      number, type = data[2].split(' ') # The response was "device,2,3 RELAY"

      type = type.downcase

      @relay_config[type] ||= {} of Int32 => String
      current = @relay_config[type].size

      (current..(current + number.to_i - 1)).each_with_index(1) do |i, dev_index|
        port = "#{address}:#{dev_index}"
        @relay_config[type][i] = port
        @port_config[port] = {type, i}
      end

      return task.try &.success
    when "endlistdevices"
      self[:num_relays] = @relay_config["relay"].size if @relay_config["relay"]?
      if @relay_config["relaysensor"]?
        @relay_config["relaysensor"][1] = "1:2"
        @relay_config["relaysensor"][2] = "1:3"
        @relay_config["relaysensor"][3] = "1:4"
        self[:num_relays] = @relay_config["relaysensor"].size
      end
      self[:num_ir] = @relay_config["ir"].size if @relay_config["ir"]?
      self[:relay_config] = @relay_config
      self[:port_config] = @port_config
      logger.debug { "self[:relay_config] is #{self[:relay_config]}" }
      logger.debug { "self[:port_config] is #{self[:port_config]}" }
      @relay_config = {} of String => Hash(Int32, String)
      @port_config = {} of String => Tuple(String, Int32)
      self[:config_indexed] = true

      return task.try &.success
    end

    if data.size == 1
      error = case data[0].split(' ')[1].to_i
              when  1 then "Command was missing the carriage return delimiter"
              when  2 then "Invalid module address when looking for version"
              when  3 then "Invalid module address"
              when  4 then "Invalid connector address"
              when  5 then "Connector address 1 is set up as \"sensor in\" when attempting to send an IR command"
              when  6 then "Connector address 2 is set up as \"sensor in\" when attempting to send an IR command"
              when  7 then "Connector address 3 is set up as \"sensor in\" when attempting to send an IR command"
              when  8 then "Offset is set to an even transition number, but should be set to an odd transition number in the IR command"
              when  9 then "Maximum number of transitions exceeded (256 total on/off transitions allowed)"
              when 10 then "Number of transitions in the IR command is not even (the same number of on and off transitions is required)"
              when 11 then "Contact closure command sent to a module that is not a relay"
              when 12 then "Missing carriage return. All commands must end with a carriage return"
              when 13 then "State was requested of an invalid connector address, or the connector is programmed as IR out and not sensor in."
              when 14 then "Command sent to the unit is not supported by the GC-100"
              when 15 then "Maximum number of IR transitions exceeded"
              when 16 then "Invalid number of IR transitions (must be an even number)"
              when 21 then "Attempted to send an IR command to a non-IR module"
              when 23 then "Command sent is not supported by this type of module"
              else         "Unknown error"
              end
      return task.try &.abort("GlobalCache error for command #{task_name}: #{error}")
    end

    task.try &.success
  end

  private def do_send(command : String, **options)
    logger.debug { "-- GlobalCache, sending: #{command}" }
    command = "#{command}#{DELIMITER}"
    send(command, **options)
  end
end
