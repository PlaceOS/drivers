require "placeos-driver/driver-specs/runner"

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
  # video_mute?
  should_send("MSEL?\r")
  responds(":MSEL=0\r")
  status[:video_mute].should eq(false)
  # volume?
  should_send("VOL?\r")
  responds(":VOL=10\r")
  status[:volume].should eq(10)
  # lamp
  should_send("LAMP?\r")
  responds(":LAMP=20\r")
  status[:lamp_usage].should eq(20)

  exec(:mute)
  should_send("MUTE ON\r")
  responds(":\r")
  should_send("MUTE?\r")
  responds(":MUTE=ON\r")
  status[:video_mute].should eq(true)
  status[:audio_mute].should eq(true)
  status[:volume].should eq(0)

  exec(:switch_to, "HDBaseT")
  should_send("SOURCE 80\r")
  responds(":\r")
  should_send("SOURCE?\r")
  responds(":SOURCE=80\r")
  status[:input].should eq("HDBaseT")
  status[:video_mute].should eq(false)

  exec(:mute_audio, false)
  should_send("VOL 10\r")
  responds(":\r")
  should_send("VOL?\r")
  responds(":VOL=10\r")
  status[:volume].should eq(10)
  status[:audio_mute].should eq(false)

  exec(:volume, 50)
  should_send("VOL 50\r")
  responds(":\r")
  should_send("VOL?\r")
  responds(":VOL=50\r")
  status[:volume].should eq(50)
  status[:audio_mute].should eq(false)
end
