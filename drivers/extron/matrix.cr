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
    # Collapse the map into a set of individual routes.
    routes = [] of SIS::Route
    seen = Set(Output).new

    insert = ->(input : Input, output : Output) do
      unless seen.add? output
        logger.warn { "conflict for output #{output} in requested map" }
      end
      routes << SIS::Route.new input, output, layer
    end

    map.each do |input, outputs|
      if outputs.is_a? Output
        insert.call input, outputs
      else
        outputs.each { |output| insert.call(input, output) }
      end
    end

    send SIS::Command["\e+Q", routes, '\r'] do |data, task|
      if data.to_s == "Qik"
        # TODO: resync tracked routes
        task.try &.success
      else
        task.try &.abort
      end
    end
  end

  def received(data, task)
    task.try &.success
  end
end
