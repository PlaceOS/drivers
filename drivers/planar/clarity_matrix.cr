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
    # options[:emit] = block if block_given?
    # options[:wait] = true
    # options[:name] = :pwr_query
    send("op A1 display.power ? \r", **options)
  end

  # def power(state, broadcast_ip = false, options = {})
  def power(state : Bool, broadcast_ip : Bool = false, **options) #guess
     puts "power method running" 
    # power? do
    #       result = self[:power]

    #       options[:delay] = 3000
    #       options[:name] = :power
    #       if is_affirmative?(state) && result == Off
    #           send("op A1 display.power = on \r", options) # changed ** -> A1: "Power should only be sent to display A1"
    #           power?
    #           schedule.in(20.seconds) do
    #               recall(0)
    #           end
    #       elsif result == On
    #           send("op A1 display.power = off \r", options) # changed ** -> A1: "Power should only be sent to display A1"
    #           power?
    #       end
    #   end
  end

  # def switch_to(*)
  #     #send("op A1 slot.recall(0) \r")

  #     # this is called when we want the whole wall to show the one thing
  #     # We'll just recall the one preset and have a different function for
  #     # video wall specific functions
  # end

  # def recall(preset, options = {})
  #     options[:name] = :recall
  #     send("op ** slot.recall (#{preset}) \r", options)
  # end

  def input_status(**options)
    options[:wait] = true
    send("op A1 slot.current ? \r", options)
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
    puts "hello"
    puts "a message to you"
    #  power?(self[:power]) { input_status priority: 0 if self[:power] == "ON" }
  end

  # protected def do_send(cmd, **options)
  #   logger.debug { "requesting: #{cmd}" }
  #   send("#{cmd}\n", **options)
  # end
end
