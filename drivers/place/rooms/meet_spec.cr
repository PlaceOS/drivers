require "placeos-driver/driver-specs/runner"
require "placeos-driver/driver-specs/mock_driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Display < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Interface::Muteable

  enum Inputs
    Hdmi
    Hdmi2
    Option
  end

  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  def on_load
    self[:power] = true
    self[:input] = Inputs::Hdmi
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
  end
end

DriverSpecs.mock_driver "Place::Rooms::Meet" do
  system({
    Display: {Display},
  })

  status["inputs"].should eq(["table", "wireless", "opc"])
  status["outputs"].should eq(["lcd"])

  exec(:route, "table", "lcd").get
  status["outputs/lcd"].as_h["source"].should eq("table")

  exec(:mute, "lcd").get
  status["outputs/lcd"].as_h["mute"].should be_true
  system(:Display_1)["audio_mute"].should be_true

  exec(:unmute, "lcd").get
  status["outputs/lcd"].as_h["mute"].should be_false
  system(:Display_1)["audio_mute"].should be_false
end
