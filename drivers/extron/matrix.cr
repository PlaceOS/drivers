require "set"
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
  # simultaneoulsy on the device.
  def switch_map(map : SignalMap, layer : SwitchLayer = SwitchLayer::All)
    ties = map.flat_map do |(input, outputs)|
      if outputs.is_a? Enumerable
        outputs.each.map { |output| Tie.new input, output, layer }
      else
        Tie.new input, outputs, layer
      end
    end

    ties.each_with_object(Set(Output).new) do |tie, seen_outputs|
      unless seen_outputs.add? tie.output
        logger.warn { "conflict for output #{tie.output} in requested map" }
      end
    end

    send Command["\e+Q", ties.map { |tie| [tie.input, '*', tie.output, tie.layer] }, '\r'], Response::Qik do
      ties.each &->update_io(Tie)
    end
  end

  # Send *command* to the device and yield a parsed response to *block*.
  private def send(command, parser : SIS::Response::Parser(T), &block : T -> Nil) forall T
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

  # Response callback for async responses.
  def received(data, task)
    case response = Response.parse data, as: Response::Unsolicited
    in Tie
      # TODO update io status
    in Error, Response::ParseError
      logger.error { response }
    in Ok
      # Nothing to see here, one of the Ignorable responses
      logger.debug { response }
    end
  end

  # Update exposed driver state to include *tie*.
  private def update_io(tie : Tie)
    case tie.layer
    in SwitchLayer::All
      self["audio#{tie.output}"] = tie.input
      self["video#{tie.output}"] = tie.input
    in SwitchLayer::Aud
      self["audio#{tie.output}"] = tie.input
    in SwitchLayer::Vid, SwitchLayer::RGB
      self["video#{tie.output}"] = tie.input
    end
  end

  # Update exposed driver state to include *switch*.
  # TODO: push state to all outputs
  private def update_io(switch : Switch)
    case switch.layer
    in SwitchLayer::All
    in SwitchLayer::Aud
    in SwitchLayer::Vid, SwitchLayer::RGB
    end
  end
end
