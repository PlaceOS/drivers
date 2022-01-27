require "placeos-driver"
require "placeos-driver/interface/switchable"

# This is a mock switch for demoing AV interfaces

class Place::Demo::Switcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  descriptive_name "PlaceOS Demo Switcher"
  generic_name :Switcher

  default_settings({
    inputs:  6,
    outputs: 6,
  })

  getter inputs : Int32 { setting(Int32, :inputs) }
  getter outputs : Int32 { setting(Int32, :outputs) }

  def on_update
    @inputs = nil
    @outputs = nil
  end

  def switch_to(input : Int32)
    raise "invalid input #{input}, supported values 0 -> #{inputs}" if input < 0 || input > inputs
    logger.debug { "switching all outputs to input #{input}" }
    (1..outputs).each { |outp| self["output#{outp}"] = input }
    true
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    logger.debug { "switching #{map} on layer #{layer || SwitchLayer::All}" }
    map.each do |input, outputs|
      outputs.each { |outp| self["output#{outp}"] = input }
    end
    true
  end
end
