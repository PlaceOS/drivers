require "placeos-driver"
require "placeos-driver/interface/powerable"

# Documentation: https://aca.im/driver_docs/Planar/020-1028-00%20RS232%20for%20Matrix.pdf
#  also https://aca.im/driver_docs/Planar/020-0567-05_WallNet_guide.pdf

class Planar::ClarityMatrix < PlaceOS::Driver
  include Interface::Powerable

  # Discovery Information
  descriptive_name "Planar Clarity Matrix Video Wall"
  generic_name :VideoWall

  # Global Cache Port
  tcp_port 4999

  def on_load
    # Communication settings
    queue.wait = false
    transport.tokenizer = Tokenizer.new("\r")
  end

  def connected
    do_poll
    schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  @power : Bool = false

  def power(state : Bool)
    power?.get
    if state && @power == false
      send("op ** display.power = on \r", name: "power", delay: 3.seconds)
      result = power?
      schedule.in(20.seconds) { recall(0) }
      result
    elsif !state && @power == true
      send("op ** display.power = off \r", name: "power", delay: 3.seconds)
      power?
    end
  end

  def power?
    send("op A1 display.power ? \r", wait: true, priority: 0)
  end

  def recall(preset : UInt32, **options)
    send("op ** slot.recall (#{preset}) \r", **options, name: "recall")
  end

  def input_status?(**options)
    send("op A1 slot.current ? \r", wait: true)
  end

  def do_poll
    power?
    input_status?(priority: 0) if @power
  end

  def build_date?
    send("ST A1 BUILD.DATE ? \r", wait: true)
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "sent: #{data}" }

    data = data.split('.') # OPA1DISPLAY.POWER=ON || OPA1SLOT.CURRENT=0
    component = data[0]    # OPA1DISPLAY || OPA1SLOT
    data = data[1].split('=')

    status = data[0].downcase.strip # POWER || CURRENT
    value = data[1].strip           # ON || 0

    case status
    when "power"
      self[:power] = @power = value == "ON"
      task.try &.success(@power)
    when "current"
      input = value.to_i
      self[:input] = input
      task.try &.success(input)
    when "date"
      # remove the inverted commas
      task.try &.success(value[1..-2])
    else
      task.try &.success
    end
  end
end
