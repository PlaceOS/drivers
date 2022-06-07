require "placeos-driver"
require "telnet"

# Documentation: https://aca.im/driver_docs/Philips/DYN_CG_INT_EnvisionGateway_R05.pdf
# See page 58

class Philips::DyNetText < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Philips DyNet Text Protocol"
  generic_name :Lighting
  tcp_port 23

  @ready : Bool = false

  def on_load
    new_telnet_client
    transport.pre_processor { |bytes| @telnet.try &.buffer(bytes) }
  end

  def connected
    @ready = false
    self[:ready] = false

    schedule.every(60.seconds) do
      logger.debug { "-- polling gateway" }
      # TODO:: send a request here
    end
  end

  def disconnected
    # Ensures the buffer is cleared
    new_telnet_client
    schedule.clear
  end

  protected def new_telnet_client
    @telnet = Telnet.new { |data| transport.send(data) }
  end

  def received(data, task)
    data = String.new(data).strip
    return if data.empty?

    logger.debug { "Dynalite sent: #{data}" }

    if @ready
      # Extract response
      process_response data.split(", "), task
    elsif data =~ /Connection Established/i
      @ready = true
      self[:ready] = true
    end
  end

  protected def process_response(parts, task)
    task.try &.success
  end
end
