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

class Switcher < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  def switch_to(input : Int32)
    self[:input] = input
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    self["last_switched_layer"] = layer.to_s.downcase
    map.each do |(input, outputs)|
      outputs.each do |output|
        self["output#{output}"] = input
      end
    end
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
        hdmi: "Switcher_1.1!video",
      },
      Switcher_1:  ["*Foo", "*Bar"],
      "*FloorBox": "Switcher_1.2",
    },
  })

  # Give the settings time to load
  sleep 2

  status["inputs"].as_a.should contain("Foo")
  status["inputs"].as_a.should contain("Bar")
  status["outputs"].as_a.should contain("Display_1")
  status["outputs"].as_a.should contain("FloorBox")
  status["output/Display_1"]["inputs"].should eq(["Foo", "Bar"])

  exec(:route, "Foo", "Display_1").get
  status["output/Display_1"]["source"].should eq(status["input/Foo"]["ref"])
  system(:Switcher_1)["last_switched_layer"].should eq("video")

  expect_raises(
    PlaceOS::Driver::RemoteException,
    %(unknown signal node "Baz" - did you mean "Bar"?)
  ) do
    exec(:route, "Foo", "Baz").get
  end

  # Ensure previous status persists settings reloads for continuing nodes
  settings({
    connections: {
      Display_1: {
        hdmi: "Switcher_1.1",
      },
      Switcher_1: ["*Foo", "*Bar"],
    },
  })
  sleep 2
  status["output/Display_1"]["source"].should eq(status["input/Foo"]["ref"])
end
