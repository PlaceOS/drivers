require "set"
require "./sis"

class Extron::Matrix < PlaceOS::Driver
  generic_name :Switcher
  descriptive_name "Extron matrix switcher"
  description "Audio-visual signal distribution device"
  tcp_port SIS::SSH_PORT

  def on_load
    transport.tokenizer = Tokenizer.new SIS::DELIMITER
  end

  alias Input = SIS::Input

  alias Output = SIS::Output

  alias SwitchLayer = SIS::SwitchLayer

  alias Outputs = Array(Output)

  alias SignalMap = Hash(Input, Output | Outputs)

  # Routes a signal *input* to an *output* at the specified *layer*.
  #
  # `0` may be used as either an input or output to specify a disconnection at
  # the corresponding signal point. For example, to disconnect input 1 from all
  # outputs is is currently feeding `switch(1, 0)`.
  def switch(input : Input, output : Output, layer : SwitchLayer = SwitchLayer::All)
    send SIS::Command[input, '*', output, layer]
  end

  # Routes *input* to all outputs at the specified *layer*.
  def switch_to(input : Input, layer : SwitchLayer = SwitchLayer::All)
    send SIS::Command[input, '*', layer]
  end

  # Applies a `SignalMap` as a single operation. All included routes will take
  # simultaneoulsy on the device.
  def switch_map(map : SignalMap, layer : SwitchLayer = SwitchLayer::All)
    routes = map.each.flat_map do |(input, outputs)|
      if outputs.is_a? Enumerable
        outputs.each.map { |output| {input, output} }
      else
        {input, outputs}
      end
    end

    seen = Set(Output).new
    routes = routes.tap do |(_, output)|
      unless seen.add? output
        logger.warn { "conflict for output #{output} in requested map" }
      end
    end

    send SIS::Command["\e+Q", routes.map { |(input, output)| [input, '*', output, layer] }, '\r']
  end

  def received(data, task)
    task.try &.success
  end
end
