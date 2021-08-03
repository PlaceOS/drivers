require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Projector::Fh" do
  exec(:power?)
  should_send("power_status ?\r\n")
  responds("\"standby\"\r\n")
  status[:power].should eq(false)

  exec(:power, true)
  should_send("power \"on\"\r\n")
  responds("ok\r\n")
  status[:power].should eq(true)

  exec(:mute?)
  should_send("blank ?\r\n")
  responds("\"on\"\r\n")
  status[:mute].should eq(true)

  exec(:mute, false)
  should_send("blank \"off\"\r\n")
  responds("ok\r\n")
  status[:mute].should eq(false)

  exec(:input?)
  should_send("input ?\r\n")
  responds("\"hdmi1\"\r\n")
  status[:input].should eq("hdmi")

  exec(:switch_to, "rgb")
  should_send("input \"rgb1\"\r\n")
  responds("ok\r\n")
  status[:input].should eq("rgb")
end
