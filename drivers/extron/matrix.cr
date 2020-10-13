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
    send Command[input, '*', output, layer], Response::Tie do |tie|
      logger.debug { "#{tie.input} -> #{tie.output} (#{tie.layer})" }
      # TODO: update io status
    end
  end

  # Connect *input* to all outputs at the specified *layer*.
  def switch_to(input : Input, layer : SwitchLayer = SwitchLayer::All)
    send Command[input, '*', layer], Response::Switch do |switch|
      logger.debug { "#{switch.input} -> all (#{switch.layer})" }
      # TODO: update io status
    end
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

    seen = Set(Output).new
    ties.each do |tie|
      unless seen.add? tie.output
        logger.warn { "conflict for output #{tie.output} in requested map" }
      end
    end

    send Command["\e+Q", ties.map { |tie| [tie.input, '*', tie.output, tie.layer] }, '\r'], Response::Qik do
      ties.each do |tie|
        logger.debug { "#{tie.input} -> #{tie.output} (#{tie.layer})" }
      end
      # TODO: update IO status
    end
  end

  # Send *command* to the device and yield a parsed response to *block*.
  private def send(command, parser : SIS::Response::Parser(T), &block : T, Task -> Nil) forall T
    send command do |data, task|
      case response = Response.parse data, parser
      in T
        result = block.call response, task
        task.success result unless task.complete?
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
      # Nothing to see here, on of the Ignorable responses
      logger.debug { response }
    end
  end
end
