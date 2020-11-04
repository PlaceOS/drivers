DriverSpecs.mock_driver "Hitachi::Projector::CpTwSeriesBasic" do
  q = {
    power: "19 D3 02 00 00 60 00 00",
    input: "CD D2 02 00 00 20 00 00",
    error: "D9 D8 02 00 20 60 00 00",
    freeze: "B0 D2 02 00 02 30 00 00",
    audio_mute: "75 D3 02 00 02 20 00 00",
    picture_mute: "CD F0 02 00 A0 20 00 00",
    lamp: "C2 FF 02 00 90 10 00 00",
    filter: "C2 F0 02 00 A0 10 00 00"
  }

  # connected
  # power?
  should_send("BEEF030600#{q[:power]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:power].should eq(true)
  # lamp?
  should_send("BEEF030600#{q[:lamp]}".delete(' ').hexbytes)
  responds("\x1d\x03\x01")
  status[:lamp].should eq(3)
  # filter?
  should_send("BEEF030600#{q[:filter]}".delete(' ').hexbytes)
  responds("\x1d\x04\x01")
  status[:filter].should eq(4)
  # error ?
  should_send("BEEF030600#{q[:error]}".delete(' ').hexbytes)
  responds("\x1d\x00\x00")
  status[:error_status].should eq("Normal")
  # input?
  should_send("BEEF030600#{q[:input]}".delete(' ').hexbytes)
  responds("\x1d\x0d\x00")
  status[:input].should eq("Hdmi2")
  # audio_mute?
  should_send("BEEF030600#{q[:audio_mute]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:audio_mute].should eq(true)
  # picture_mute?
  should_send("BEEF030600#{q[:picture_mute]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:picture_mute].should eq(true)
  # freeze?
  should_send("BEEF030600#{q[:freeze]}".delete(' ').hexbytes)
  responds("\x1d\x01\x00")
  status[:frozen].should eq(true)

  # exec(:power, false)
  # should_send("BEEF030600 BA D2 01 00 00 60 01 00".delete(' ').hexbytes)
end
