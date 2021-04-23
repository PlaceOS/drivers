class PlaceOS::Driver; end

require "placeos-driver/driver-specs/runner"
require "placeos-driver/driver-specs/mock_driver"
require "placeos-driver/task"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

class Display < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Powerable
  include PlaceOS::Driver::Interface::Muteable
  include PlaceOS::Driver::Interface::InputSelection(String)

  def on_load
    self[:power] = true
    self[:input] = "hdmi"
  end

  # implement the abstract methods required by the interfaces
  def power(state : Bool)
    self[:power] = state
  end

  def switch_to(input : String)
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

class Switcher < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::InputSelection(Int32)

  def switch_to(input : Int32)
    self[:input] = input
  end

  def mute(state : Bool)
    self[:audio_mute] = state
  end

  def volume(level : Int32)
    self[:volume] = level.clamp 0, 100
  end
end

DriverSpecs.mock_driver "Place::Rooms::Present" do
  system({
    Switcher: {Switcher},
    Projector: {Display},
    Display: {Display, Display, Display, Display},
  })

  exec(:powerup).get
  status["active"].should be_true

  exec(:route, "hdmi", "proj").get
  status["output/proj"].as_h["source"].should eq("hdmi")

  exec(:route, "pc", "proj").get
  status["output/proj"].as_h["source"].should eq("pc")

  exec(:mute).get
  status["mute"].should be_true
  status["output/proj"].as_h["mute"].should be_true
  system(:Switcher_1)["audio_mute"].should be_true

  exec(:unmute).get
  status["mute"].should be_false
  status["output/proj"].as_h["mute"].should be_false
  system(:Switcher_1)["audio_mute"].should be_false

  exec(:volume, 50).get
  status["volume"].should eq(50)
  status["output/proj"].as_h["volume"].should eq(50)
  system(:Switcher_1)["volume"].should eq(50)

  exec(:shutdown).get
  status["active"].should be_false
end
