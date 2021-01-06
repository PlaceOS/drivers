DriverSpecs.mock_driver "Qsc::QSysControl" do
  settings({
    username: "user",
    password: "pass",
    emergency: "6"
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

  exec(:phone_watch, "0")
  should_send("cgc 31\n")
  responds("none\r\n")
  should_send("cgsna 31 2000\n")
  responds("none\r\n")
  should_send("cga 31 0\n")
  responds("none\r\n")

  exec(:phone_watch, ["1","2"])
  should_send("cga 31 1\n")
  responds("none\r\n")
  should_send("cga 31 2\n")
  responds("none\r\n")

  exec(:mute, ["1","2","3"], true)
  should_send("csv \"1\" 1\n")
  responds("none\r\n")
  should_send("csv \"2\" 1\n")
  responds("none\r\n")
  should_send("csv \"3\" 1\n")
  responds("none\r\n")
end
