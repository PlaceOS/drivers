require "driver/interface/muteable"
require "driver/interface/powerable"
require "driver/interface/switchable"

class Display < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Interface::Muteable

  enum Inputs
    HDMI
    HDMI2
    VGA
    VGA2
    Miracast
    DVI
    DisplayPort
    HDBaseT
    Composite
  end

  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  # Configure initial state in on_load
  def on_load
    self[:power] = false
    self[:input] = Inputs::HDMI
  end

  # implement the abstract methods required by the interfaces
  def power(state : Bool)
    self[:power] = state
  end

  def switch_to(input : Inputs)
    mute(false)
    self[:input] = input
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    self[:mute] = state
    self[:mute0] = state
  end
end

class Switcher < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::InputSelection(Int32)

  def switch_to(input : Input)
    self[:output] = input
  end
end

DriverSpecs.mock_driver "Place::LogicExample" do
  system({
    Display:  {Display, Display},
    Switcher: {Switcher},
  })

  exec(:power_state?).get.should eq(false)

  # Should allow updating of settings
  settings({
    name: "Steve",
  })

  # Updating emulated module state
  system(:Display_1)[:power] = true
  exec(:power_state?).get.should eq(true)

  # Expecting a function call
  exec(:power, false)
  exec(:power_state?).get.should eq(false)
  system(:Display_1)[:power].should eq(false)

  # Expecting a function call to return a result
  exec(:power, true).get.should eq(true)

  exec(:display_count).get.should eq(2)

  system({
    Display:  {Display},
    Switcher: {Switcher},
  })

  exec(:display_count).get.should eq(1)
end
