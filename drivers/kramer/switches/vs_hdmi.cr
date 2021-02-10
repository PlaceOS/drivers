# Documentation: https://aca.im/driver_docs/Kramer/Kramer%20protocol%202000%20v0.51.pdf

class Kramer::Switcher::VsHdmi < PlaceOS::Driver
  # Discovery Information
  tcp_port 23
  descriptive_name "Kramer Protocol 2000 Switcher"
  generic_name :Switcher

  @limits_known : Bool = false

  def on_load
    queue.delay = 150.milliseconds
    queue.wait = false
  end

  def connected
    get_machine_type
  end

  private def get_machine_type
    #              id com,    video
    command = Bytes[62, 0x81, 0x81, 0xFF]
    send(command, name: :inputs) # num inputs
    command = Bytes[62, 0x82, 0x81, 0xFF]
    send(command, name: :outputs) # num outputs
  end

  enum Command
    ResetVideo = 0
    SwitchVideo = 1
    StatusVideo = 5
    DefineMachine = 62
    IdentifyMachine = 61
  end

  def switch(map : Hash(Int32, Array(Int32)))
    # instr, inp,  outp, machine number
    # Switch video
    command = Bytes[1, 0x80, 0x80, 0xFF]

    map.each do |input, outputs|
      outputs.each do |output|
        command[1] += input
        command[2] += output
        outname = "video#{output}"
        send(command, name: outname)
        self[outname] = input
      end
    end
  end

  def received(data, task)
    logger.debug { "Kramer sent 0x#{data.hexstring}" }

    # Only process response if we are the destination
    return unless data[0].bit(6) == 1
    input = data[1] & 0b111_111
    output = data[2] & 0b111_111
    command = Command.from_value(data[0] & 0b111_111)
    pp "command is #{command}"

    case command
    when .define_machine?
      if input == 1
        self[:video_inputs] = output
      elsif input == 2
        self[:video_outputs] = output
      end
      @limits_known = true # Set here in case unsupported
    when .status_video?
      if output == 0 # Then input has been applied to all the outputs
        logger.debug { "Kramer switched #{input} -> All" }

        (1..self[:video_outputs].as_i).each { |i| self["video#{i}"] = input }
      else
        self["video#{output}"] = input

        logger.debug { "Kramer switched #{input} -> #{output}" }

        # As we may not know the max number of inputs if get_machine_type didn't work
        self[:video_inputs] = input if input > self[:video_inputs].as_i
        self[:video_outputs] = output if output > self[:video_outputs].as_i
      end
    when .identify_machine?
      logger.debug { "Kramer switcher protocol #{input}.#{output}" }
    end

    task.try &.success
  end
end
