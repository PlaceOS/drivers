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
    send Command[input, '*', output, layer] do |data, task|
      case result = Response.parse data, as: Response::Tie
      in Tie
        task.success
      in Error
        result.retryable? ? task.retry result : task.abort result
      in Response::ParseError
        task.abort result
      end
    end
  end

  # Connect *input* to all outputs at the specified *layer*.
  def switch_to(input : Input, layer : SwitchLayer = SwitchLayer::All)
    send Command[input, '*', layer]
  end

  # Applies a `SignalMap` as a single operation. All included ties will take
  # simultaneoulsy on the device.
  def switch_map(map : SignalMap, layer : SwitchLayer = SwitchLayer::All)
    ties = map.each.flat_map do |(input, outputs)|
      if outputs.is_a? Enumerable
        outputs.each.map { |output| Tie.new input, output, layer }
      else
        Tie.new input, outputs, layer
      end
    end

    seen = Set(Output).new
    ties = ties.tap do |tie|
      unless seen.add? tie.output
        logger.warn { "conflict for output #{tie.output} in requested map" }
      end
    end

    send Command["\e+Q", ties.map { |tie| [tie.input, '*', tie.output, tie.layer] }, '\r']
  end

  def received(data, task)
    case response = Response.parse data, as: Response::Unsolicited
    in Tie
      # TODO update status
    in Error, Response::ParseError
      logger.error { response }
    in Response::Ignored
      logger.debug { response.object }
    end
  end
end
