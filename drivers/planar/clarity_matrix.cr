module Planar; end

require "placeos-driver/interface/powerable"

# Documentation: https://aca.im/driver_docs/Planar/020-1028-00%20RS232%20for%20Matrix.pdf
#  also https://aca.im/driver_docs/Planar/020-0567-05_WallNet_guide.pdf

class Planar::ClarityMatrix < PlaceOS::Driver
  include Interface::Powerable

  # Discovery Information
  generic_name :VideoWall
  descriptive_name "Planar Clarity Matrix Video Wall"

  #   implements :device # don't need?

  def on_load
    # Communication settings
    queue.wait = false
    transport.tokenizer = Tokenizer.new("\r")
  end

  def on_unload
  end

  def on_update
  end

  def connected
    schedule.every(60.seconds) { do_poll }
    do_poll
  end

  def disconnected
    # Disconnected may be called without calling connected
    #   Hence the check if timer is nil here

    schedule.clear
  end

  # def power?(options = {}, &block)
  def power?(**options)
    #  no optional block in crystal unless overloading
    # options[:emit] = block if block_given?

    # options[:wait] = true
    # options[:name] = :pwr_query
    send("op A1 display.power ? \r", **options)
  end

  # def power(state, broadcast_ip = false, options = {})
  # what does broadcast_ip do here??
  def power(state : Bool = false)
    puts "power method running" 
    # self[:power] = state
    # send("op A1 display.power = off \r")
    if state == true
      send("op A1 display.power = on \r") # changed ** -> A1: "Power should only be sent to display A1"
      power?
      schedule.in(20.seconds) { recall(0) }
    else
      send("op A1 display.power = off \r") # changed ** -> A1: "Power should only be sent to display A1"
      power?
    end
  end

  def switch_to
    send "op A1 slot.recall(0) \r"

    # this is called when we want the whole wall to show the one thing
    # We'll just recall the one preset and have a different function for
    # video wall specific functions
  end

  def recall(preset : Int32, **options)
      # options[:name] = :recall
      send "op ** slot.recall #{preset} \r", **options # removed parentheses around preset
  end

  def input_status(**options)
    # options[:wait] = true
    send "op A1 slot.current ? \r", **options
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
    puts "running do_poll"
    power?(priority: 0) 
    # input_status(priority: 0) if self["power"] == "ON" # check if this block is running
  end
end
