require "./sis"

class Extron::Matrix < PlaceOS::Driver
  include Extron::SIS

  generic_name :Switcher
  descriptive_name "Extron matrix switcher"
  description "Audio-visual signal distribution device"
  tcp_port SSH_PORT

  def on_load
    transport.tokenizer = Tokenizer.new DELIMITER
  end

  def connected
    send Command['I'], Response::SwitcherInformation do |info|
      @device_size = info
    end
  end

  def disconnected
    @device_size = nil
  end

  getter device_size do
    empty = MatrixSize.new 0, 0
    SwitcherInformation.new empty, empty
  end

  alias Outputs = Array(Output)

  alias SignalMap = Hash(Input, Output | Outputs)

  # Connect a signal *input* to an *output* at the specified *layer*.
  #
  # `0` may be used as either an input or output to specify a disconnection at
  # the corresponding signal point. For example, to disconnect input 1 from all
  # outputs is is currently feeding `switch(1, 0)`.
  def switch(input : Input, output : Output, layer : SwitchLayer = SwitchLayer::All)
    send Command[input, '*', output, layer], Response::Tie, &->update_io(Tie)
  end

  # Connect *input* to all outputs at the specified *layer*.
  def switch_to(input : Input, layer : SwitchLayer = SwitchLayer::All)
    send Command[input, '*', layer], Response::Switch, &->update_io(Switch)
  end

  # Applies a `SignalMap` as a single operation. All included ties will take
  # simultaneously on the device.
  def switch_map(map : SignalMap, layer : SwitchLayer = SwitchLayer::All)
    ties = map.flat_map do |(input, outputs)|
      if outputs.is_a? Enumerable
        outputs.each.map { |output| Tie.new input, output, layer }
      else
        Tie.new input, outputs, layer
      end
    end

    conflicts = ties - ties.uniq(&.output)
    unless conflicts.empty?
      raise ArgumentError.new "map contains conflicts for output(s) #{conflicts.map(&.output).join ","}"
    end

    send Command["\e+Q", ties.map { |tie| [tie.input, '*', tie.output, tie.layer] }, '\r'], Response::Qik do
      ties.each &->update_io(Tie)
    end
  end

  # Send *command* to the device and yield a parsed response to *block*.
  private def send(command, parser : SIS::Response::Parser(T), &block : T -> _) forall T
    send command do |data, task|
      case response = Response.parse data, parser
      in T
        task.success block.call response
      in Error
        response.retryable? ? task.retry response : task.abort response
      in Response::ParseError
        task.abort response
      end
    end
  end

  private def send(command, parser : SIS::Response::Parser(T)) forall T
    send command, parser, &.itself
  end

  # Response callback for async responses.
  def received(data, task)
    case response = Response.parse data, as: Response::Unsolicited
    in Tie
      update_io response
    in Error, Response::ParseError
      logger.error { response }
    in Ok
      # Nothing to see here, one of the Ignorable responses
      logger.debug { response }
    end
  end

  private def update_io(input : Input, output : Output, layer : SwitchLayer)
    self["audio#{output}"] = input if layer.includes_audio?
    self["video#{output}"] = input if layer.includes_video?
  end

  private def update_io(tie : Tie)
    update_io tie.input, tie.output, tie.layer
  end

  # Update exposed driver state to include *switch*.
  private def update_io(switch : Switch)
    if switch.layer.includes_video?
      device_size.video.outputs.times { |o| update_io switch.input, Output.new(o + 1), SwitchLayer::Vid }
    end
    if switch.layer.includes_audio?
      device_size.audio.outputs.times { |o| update_io switch.input, Output.new(o + 1), SwitchLayer::Aud }
    end
  end
end
