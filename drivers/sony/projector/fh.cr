require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

# Documentation: https://drive.google.com/a/room.tools/file/d/1C0gAWNOtkbrHFyky_9LfLCkPoMcYU9lO/view?usp=sharing

class Sony::Projector::Fh < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  descriptive_name "Sony Projector FH Series"
  generic_name :Display

  def connected
    schedule.every(60.seconds) { do_poll }
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
  end

  def power?(priority : Int32 = 0, **options)
  end

  def switch_to(input : Input)
  end

  def input?
  end

  def lamp_time?
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
  end

  def mute?
  end

  private def do_poll
  end

  INDICATOR = 0xA9_u8
  DELIMITER = 0x9A_u8

  private def do_send(type : Type, command : Command, param : Bytes = Bytes.new(2), **options)
    send(data, **options)
  end

  def received(data, task)
    task.try &.success
  end
end
