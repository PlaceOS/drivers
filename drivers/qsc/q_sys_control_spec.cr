require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Qsc::QSysControl" do
  settings({
    username:  "user",
    password:  "pass",
    emergency: "6",
  })

  should_send("login user pass\n")
  responds("login_success\r\n")
  should_send("cgc 30\n")
  responds("none\r\n")
  should_send("cgsna 30 2000\n")
  responds("none\r\n")
  should_send("cga 30 6\n")
  responds("none\r\n")

  exec(:about)
  should_send("sg\n")
  responds("sr \"MyDesign\" \"NIEC2bxnVZ6a\" 1 1\r\n")
  status[:design_name].should eq("MyDesign")
  status[:is_primary].should eq(true)
  status[:is_active].should eq(true)

  exec(:mute, ["1", "2", "3"], true)
  should_send("csv \"1\" 1\n")
  responds("cv \"1\" \"control string\" 1 8\r\n")
  status[:pos_1].should eq(8)
  status[:fader1_mute].should eq(true)
  should_send("csv \"2\" 1\n")
  responds("cv \"2\" \"control string\" 1 5\r\n")
  status[:pos_2].should eq(5)
  status[:fader2_mute].should eq(true)
  should_send("csv \"3\" 1\n")
  responds("cv \"3\" \"control string\" 1 4\r\n")
  status[:pos_3].should eq(4)
  status[:fader3_mute].should eq(true)

  exec(:faders, ["1", "2", "3"], 90)
  should_send("csv \"1\" 9.0\n")
  responds("cv \"1\" \"control string\" 9 6\r\n")
  status[:pos_1].should eq(6)
  status[:fader1_mute].should eq(true)
  should_send("csv \"2\" 9.0\n")
  responds("cv \"2\" \"control string\" 9 7\r\n")
  status[:pos_2].should eq(7)
  status[:fader2].should eq(90)
  should_send("csv \"3\" 9.0\n")
  responds("cv \"3\" \"control string\" 9 8\r\n")
  status[:pos_3].should eq(8)
  status[:fader3].should eq(90)

  exec(:phone_watch, "0")
  should_send("cgc 31\n")
  responds("none\r\n")
  should_send("cgsna 31 2000\n")
  responds("none\r\n")
  should_send("cga 31 0\n")
  responds("none\r\n")

  exec(:phone_watch, ["1", "2"])
  should_send("cga 31 1\n")
  responds("none\r\n")
  should_send("cga 31 2\n")
  responds("none\r\n")

  exec(:phone_number, "0123456789", "1")
  should_send("css \"1\" \"0123456789\"\n")
  responds("cv \"1\" \"0123456789\" 9 8\r\n")
  status[:"1"].should eq("0123456789")
end
