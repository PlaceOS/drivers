module Planar; end

require "placeos-driver/interface/powerable"

# Documentation: https://aca.im/driver_docs/Planar/020-1028-00%20RS232%20for%20Matrix.pdf
#  also https://aca.im/driver_docs/Planar/020-0567-05_WallNet_guide.pdf

class Planar::ClarityMatrix < PlaceOS::Driver
  include Interface::Powerable

  # Discovery Information
  generic_name :VideoWall
  descriptive_name "Planar Clarity Matrix Video Wall"

  def on_load
    # Communication settings
    queue.wait = false
    transport.tokenizer = Tokenizer.new("\r")
  end

  def connected
    schedule.every(60.seconds, true) { do_poll }
  end

  def disconnected
    # Disconnected may be called without calling connected
    #   Hence the check if timer is nil here

    schedule.clear
  end

  def power?
    # options[:emit] = block if block_given?

    # options[:wait] = true
    # options[:name] = :pwr_query
    send("op A1 display.power ? \r")
  end

  # def power(state, broadcast_ip = false, options = {})
  # what does broadcast_ip do here??
  def power(state : Bool = false)
    # self[:power] = state
    # send("op A1 display.power = off \r")
    if state == true
      send("op A1 display.power = on \r")
      schedule.in(20.seconds) { recall(0) }
    else
      send("op A1 display.power = off \r")
    end
  end

  def switch_to
    send "op A1 slot.recall(0) \r"

    # this is called when we want the whole wall to show the one thing
    # We'll just recall the one preset and have a different function for
    # video wall specific functions
  end

  def recall(preset : Int32)
      # options[:name] = :recall
      send "op ** slot.recall #{preset} \r"
  end

  def input_status
    # options[:wait] = true
    send "op A1 slot.current ? \r"
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Vid Wall: #{data}" }

    data = data.split(".") # OPA1DISPLAY.POWER=ON || OPA1SLOT.CURRENT=0
    component = data[0]    # OPA1DISPLAY || OPA1SLOT
    data = data[1].split("=")

    status = data[0].downcase # POWER || CURRENT
    value = data[1]           # ON || 0

    case status
    when "power"
      self["power"] = value == "ON"
    when "current"
      self[:input] = value.to_i
    end

    task.try &.success(data)
  end

  protected def do_poll
    power?
    input_status if self["power"] == "ON"
  end
end
