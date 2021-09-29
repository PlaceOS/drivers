require "placeos-driver/spec"

DriverSpecs.mock_driver "Biamp::Nexia" do
  should_send "\xFF\xFE\x01"

  should_send("GETD 0 DEVID\n")
  responds("#GETD 0 DEVID 1\r\n")
  status["device_id"].should eq(1)

  exec(:preset, 1001)
  should_send("RECALL 0 PRESET 1001\n")
  responds("#RECALL 0 PRESET 1001 +OK\r\n")

  exec(:fader, 1, 0.0)
  should_send("SETD 1 FDRLVL 1 1 -100.0\n")
  responds("#SETD 1 FDRLVL 1 1 -100.0 +OK\r\n")
  status["fader1_1"].should eq(0.0)

  exec(:fader, 1, 100.0, 2, "matrix_in")
  should_send("SETD 1 MMLVLIN 1 2 12.0\n")
  responds("#SETD 1 MMLVLIN 1 2 12.0 +OK\r\n")
  status["matrix_in1_2"].should eq(100.0)

  exec(:mute, 1234, false, 3)
  should_send("SETD 1 FDRMUTE 1234 3 0\n")
  responds("#SETD 1 FDRMUTE 1234 3 0 +OK\r\n")
  status["fader1234_3_mute"].should eq(false)

  exec(:mute, 1234, true, 5, "auto_in")
  should_send("SETD 1 AMMUTEIN 1234 5 1\n")
  responds("#SETD 1 AMMUTEIN 1234 5 1 +OK\r\n")
  status["auto_in1234_5_mute"].should eq(true)

  exec(:unmute, 111)
  should_send("SETD 1 FDRMUTE 111 1 0\n")
  responds("#SETD 1 FDRMUTE 111 1 0 +OK\r\n")
  status["fader111_1_mute"].should eq(false)

  exec(:query_fader, 133)
  should_send("GETD 1 FDRLVL 133 1\n")
  responds("#GETD 1 FDRLVL 133 1 -100.0\r\n")
  status["fader133_1"].should eq(0.0)

  exec(:query_mute, 155)
  should_send("GETD 1 FDRMUTE 155 1\n")
  responds("#GETD 1 FDRMUTE 155 1 0\r\n")
  status["fader155_1_mute"].should eq(false)
end
