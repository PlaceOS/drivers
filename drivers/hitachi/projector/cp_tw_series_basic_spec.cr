require "placeos-driver"
require "./cp_tw_series_basic"

DriverSpecs.mock_driver "Hitachi::Projector::CpTwSeriesBasic" do
  c = Hitachi::Projector::CpTwSeriesBasic::Commands

  # connected
  # power?
  should_send("BEEF030600#{c[:power?]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:power].should eq(true)
  # lamp?
  should_send("BEEF030600#{c[:lamp?]}".delete(' ').hexbytes)
  responds("\x1d\x03\x01")
  status[:lamp].should eq(3)
  # filter?
  should_send("BEEF030600#{c[:filter?]}".delete(' ').hexbytes)
  responds("\x1d\x04\x01")
  status[:filter].should eq(4)
  # error?
  should_send("BEEF030600#{c[:error?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:error_status].should eq("Normal")
  # input?
  should_send("BEEF030600#{c[:input?]}".delete(' ').hexbytes)
  responds("\x1d\x0d\x00")
  status[:input].should eq("Hdmi2")
  # audio_mute?
  should_send("BEEF030600#{c[:audio_mute?]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:audio_mute].should eq(true)
  # video_mute?
  should_send("BEEF030600#{c[:video_mute?]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:video_mute].should eq(true)
  # freeze?
  should_send("BEEF030600#{c[:freeze?]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:frozen].should eq(true)

  exec(:mute, false)
  should_send("BEEF030600#{c[:unmute_video]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:video_mute?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:video_mute].should eq(false)
  should_send("BEEF030600#{c[:unmute_audio]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:audio_mute?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:video_mute].should eq(false)

  exec(:switch_to, "hdmi")
  should_send("BEEF030600#{c[:hdmi]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:input?]}".delete(' ').hexbytes)
  responds("\x1d\x03\x00")
  status[:input].should eq("Hdmi")

  exec(:lamp_hours_reset)
  should_send("BEEF030600#{c[:lamp_hours_reset]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:lamp?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:lamp].should eq(0)

  exec(:filter_hours_reset)
  should_send("BEEF030600#{c[:filter_hours_reset]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:filter?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:filter].should eq(0)

  exec(:power, false)
  should_send("BEEF030600#{c[:power_off]}".delete(' ').hexbytes)
  responds("\x06")
  should_send("BEEF030600#{c[:power?]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:power].should eq(false)
end
