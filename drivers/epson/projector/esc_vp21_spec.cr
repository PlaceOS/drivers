require "placeos-driver/spec"

DriverSpecs.mock_driver "Epson::Projector::EscVp21" do
  # connected
  should_send("ESC/VP.net\x10\x03\x00\x00\x00\x00")
  responds(":\r")
  # do_poll
  # power?
  should_send("PWR?\r")
  responds(":PWR=01\r")
  status[:power].should eq(true)
  # input?
  should_send("SOURCE?\r")
  responds(":SOURCE=30\r")
  status[:input].should eq("HDMI")
  # volume?
  responds(":VOL=0\r")
  status[:volume].should eq(0)
  # lamp
  responds(":LAMP=20\r")
  status[:lamp_usage].should eq(20)

  # IMEVENT test - projector on
  transmit(":IMEVENT=0001 03 00000000 00000000 T1 F1\r")
  status[:power].should eq(true)
  status[:warming].should eq(false)
  status[:cooling].should eq(false)

  exec(:mute)
  responds(":\r")
  responds(":MUTE=ON\r")
  status[:video_mute].should eq(true)
  status[:audio_mute].should eq(true)
  status[:volume].should eq(0)

  exec(:switch_to, "HDBaseT")
  should_send("SOURCE 80\r")
  responds(":\r")
  responds(":SOURCE=80\r")
  status[:input].should eq("HDBaseT")
  status[:video_mute].should eq(false)

  exec(:mute_audio, false)
  should_send("VOL 153\r")
  responds(":\r")
  responds(":VOL=255\r")
  status[:volume].should eq(100)
  status[:audio_mute].should eq(false)

  exec(:volume, 80)
  should_send("VOL 204\r")
  responds(":\r")
  responds(":VOL=204\r")
  status[:volume].should eq(80)
  status[:audio_mute].should eq(false)

  # Additional IMEVENT tests
  # Test warming state
  transmit(":IMEVENT=0001 02 00000000 00000000 T1 F1\r")
  status[:power].should eq(false)
  status[:warming].should eq(true)
  status[:cooling].should eq(false)

  # Test cooling state
  transmit(":IMEVENT=0001 04 00000000 00000000 T1 F1\r")
  status[:power].should eq(false)
  status[:warming].should eq(false)
  status[:cooling].should eq(true)

  # Test with warnings and alarms
  transmit(":IMEVENT=0001 03 00000003 00000007 T1 F1\r")
  status[:power].should eq(true)
  status[:warnings].should eq(["Lamp life", "No signal"])
  status[:alarms].should eq(["Lamp ON failure", "Lamp lid", "Lamp burnout"])
end
