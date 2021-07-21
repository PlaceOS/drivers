require "placeos-driver/driver-specs/runner"
require "placeos-driver/driver-specs/mock_driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Display < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Interface::Muteable

  enum Inputs
    HDMI
    HDMI2
  end
  include PlaceOS::Driver::Interface::InputSelection(Inputs)

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
  end
end

# :nodoc:
class Switcher < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  def switch_to(input)
  end

  def switch(map)
  end
end

DriverSpecs.mock_driver "Place::Router" do
  system({
    Display:  {Display},
    Switcher: {Switcher},
  })

  settings({
    connections: {
      Display_1: {
        hdmi: "Switcher_1.1",
      },
      Switcher_1: ["*Foo", "*Bar"],
    },
  })

  #exec(:route, "a", "b").get.should eq("foo")
end
