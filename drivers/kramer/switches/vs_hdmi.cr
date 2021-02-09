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
    #         id com,    video
    command = Bytes[62, 0x81, 0x81, 0xFF]
    send(command, name: :inputs) # num inputs
    command[1] = 0x82
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

    return if data[0] & 0b1000000 == 0 # Check we are the destination

    data[1] = data[1] & 0b1111111 # input
    data[2] = data[2] & 0b1111111 # output

    case Command.from_value(data[0] & 0b111111)
    when .define_machine?
      if data[1] == 1
        self[:video_inputs] = data[2]
      elsif data[1] == 2
        self[:video_outputs] = data[2]
      end
      @limits_known = true # Set here in case unsupported
    when .status_video?
      if data[2] == 0 # Then data[1] has been applied to all the outputs
        logger.debug { "Kramer switched #{data[1]} -> All" }

        (1..self[:video_outputs].as_i).each { |i| self["video#{i}"] = data[1] }
      else
        self["video#{data[2]}"] = data[1]

        logger.debug { "Kramer switched #{data[1]} -> #{data[2]}" }

        # As we may not know the max number of inputs if get_machine_type didn't work
        self[:video_inputs] = data[1] if data[1] > self[:video_inputs].as_i
        self[:video_outputs] = data[2] if data[2] > self[:video_outputs].as_i
      end
    when .identify_machine?
      logger.debug { "Kramer switcher protocol #{data[1]}.#{data[2]}" }
    end

    task.try &.success
  end
end
