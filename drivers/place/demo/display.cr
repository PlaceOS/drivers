require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Place::Demo::Display < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    DVI         =  1
    HDMI        = 10
    HDMI2       = 13
    HDMI3       = 18
    DisplayPort = 14
    VGA         =  2
    VGA2        = 16
    Component   =  3
  end

  include Interface::InputSelection(Input)

  descriptive_name "PlaceOS Demo Display"
  generic_name :Display

  def power(state : Bool)
    self[:power] = state
  end

  def power?(**options)
    self[:power].as_bool
  end

  def switch_to(input : Input)
    self[:input] = input
  end

  getter? volume : Float64 = 0.0

  def volume(level : Int32 | Float64)
    self[:volume] = @volume = level.to_f64
  end

  def test_setting(key : String, payload : JSON::Any)
    define_setting(key, payload)
    payload
  end

  # There seems to only be audio mute available
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    self[:audio_mute] = state
    self[:volume] = state ? 0 : @volume
  end
end
