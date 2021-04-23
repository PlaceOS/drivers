require "placeos-driver/driver-specs/runner"
require "placeos-driver/driver-specs/mock_driver"
require "placeos-driver/task"
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
    self[:audio_mute] = state
  end

  def volume(level : Int32)
    self[:volume] = level.clamp 0, 100
  end
end

DriverSpecs.mock_driver "Place::Rooms::Meet" do
  system({
    Display: {Display},
  })

  status["inputs"].should eq(["table", "wireless", "opc"])
  status["outputs"].should eq(["lcd"])

  exec(:powerup).get
  status["active"].should be_true

  exec(:route, "table", "lcd").get
  status["output/lcd"].as_h["source"].should eq("table")

  exec(:mute).get
  status["mute"].should be_true
  status["output/lcd"].as_h["mute"].should be_true
  system(:Display_1)["audio_mute"].should be_true

  exec(:unmute).get
  status["mute"].should be_false
  status["output/lcd"].as_h["mute"].should be_false
  system(:Display_1)["audio_mute"].should be_false

  exec(:volume, 50).get
  status["volume"].should eq(50)
  status["output/lcd"].as_h["volume"].should eq(50)
  system(:Display_1)["volume"].should eq(50)

  exec(:shutdown).get
  status["active"].should be_false
end
