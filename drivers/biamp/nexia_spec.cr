DriverSpecs.mock_driver "Biamp::Nexia" do
  should_send "\xFF\xFE\x01"
  should_send("GETD 0 DEVID\n")
  responds("#GETD 0 DEVID 1\r\n")
  status["device_id"].should eq(1)

  exec(:preset, 1001)
  should_send("RECALL 0 PRESET 1001\n")
  responds("#RECALL 0 PRESET 1001 +OK\r\n")

  exec(:fader, 1, -100)
  should_send("SETD 1 FDRLVL 1 1 -100.0\n")
  responds("#SETD 1 FDRLVL 1 1 -100.0\r\n")
  status["fader1_1"].should eq(-100.0)

  exec(:faders, 1, -75, 2, "matrix_in")
  should_send("SETD  MMLVLIN 1 2 -75.0")
  responds("#SETD  MMLVLIN 1 2 -75.0\r\n")
  status["matrix_in1_2"].should eq(-75.0)

  exec(:mute, 1234, false, 3)
  should_send("SETD  FDRMUTE 1234 3 0\n")
  responds("#SETD  FDRMUTE 1234 3 0\r\n")
  status["fader1234_3_mute"].should eq(false)

  exec(:mutes, 1234, true, 5, "auto_in")
  should_send("SETD  AMMUTEIN 1234 5 1\n")
  responds("#SETD  AMMUTEIN 1234 5 1\r\n")
  status["auto_in1234_5_mute"].should eq(true)

  exec(:unmute, 111)
  should_send("SETD  FDRMUTE 111 1 0\n")
  responds("#SETD  FDRMUTE 111 1 0\r\n")
  status["fader111_1_mute"].should eq(false)

  exec(:query_fader, 133)
  should_send("GETD  FDRLVL 133 1\n")
  responds("#GETD  FDRLVL 133 1 -100.0\r\n")
  status["fader133_1"].should eq(-100.0)

  exec(:query_faders, 144)
  should_send("GETD  FDRLVL 144 1\n")
  responds("GETD  FDRLVL 144 1 -80.0\r\n")
  status["fader144_1"].should eq(-80.0)

  exec(:query_mute, 155)
  should_send("GETD  FDRMUTE 155 1\n")
  responds("#GETD  FDRMUTE 155 1 0\r\n")
  status["fader155_1_mute"].should eq(false)

  exec(:query_mutes, 166)
  should_send("GETD  FDRMUTE 166 1\n")
  responds("#GETD  FDRMUTE 166 1 1\r\n")
  status["fader166_1_mute"].should eq(true)
end
