module Bose; end

# Documentation: https://aca.im/driver_docs/Bose/Bose-ControlSpace-SerialProtocol-v5.pdf

class Bose::ControlSpaceSerial < PlaceOS::Driver
  # Discovery Information
  tcp_port 10055
  descriptive_name "Bose ControlSpace Serial Protocol"
  generic_name :Mixer

  def on_load
    # 0x0D (<CR> carriage return \r)
    transport.tokenizer = Tokenizer.new(Bytes[0x0D])
    on_update
  end

  def on_update
  end

  def connected
    schedule.every(60.seconds) do
      logger.debug "-- maintaining connection"
      do_send "GS", priority: 99
    end
  end

  def disconnected
    schedule.clear
  end

  private def do_send(data, **options)
    logger.debug { "requesting: #{data}" }
    send "#{data}\x0D", **options
  end

  def set_parameter_group(id : UInt8)
    do_send("SS #{id.to_s(16).upcase}", wait: false).get
    self[:parameter_group] = id
  end

  def get_parameter_group
    do_send "GS"
  end

  def received(data, task)
    # Ignore the framing bytes
    data = String.new(data).rchop
    logger.debug { "ControlSpace sent: #{data}" }

    parts = data.split(" ")
    case parts[0]
    when "S"
      self[:parameter_group] = parts[1].to_i(16)
    end

    task.try &.success
  end
end
