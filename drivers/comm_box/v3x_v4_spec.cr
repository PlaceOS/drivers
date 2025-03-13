require "placeos-driver/spec"

DriverSpecs.mock_driver "CommBox::V3X_V4" do
  exec(:power, true)
  should_send("!200POWR 1\r")
  responds("!201POWR=1\r")
  status[:power].should eq(true)

  exec(:power?)
  should_send("!200POWR ?\r")
  responds("!201POWR=1\r")

  exec(:volume, 24)
  should_send("!200VOLM 24\r")
  responds("!201VOLM=24\r")

  exec(:volume, 6)
  should_send("!200VOLM 6\r")
  responds("!201VOLM=6\r")

  exec(:mute, true)
  # Audio mute
  should_send("!200MUTE 1\r")
  responds("!201MUTE=1\r")

  exec(:mute, false)
  # Audio mute
  should_send("!200MUTE 0\r")
  responds("!201MUTE=0\r")

  exec(:switch_to, "hdmi")
  should_send("!200INPT 211\r")
  responds("!201INPT=211\r")
end
