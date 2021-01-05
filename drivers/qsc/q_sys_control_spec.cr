DriverSpecs.mock_driver "Qsc::QSysControl" do
  settings({
    username: "user",
    password: "pass",
    # emergency: 1
  })

  # should_send("login user pass\n")
  # responds("login_success\r\n")

  exec(:about)
  should_send("sg\n")
  responds("sr designname two 1 1\r\n")
  status[:design_name].should eq("designname")
  status[:is_primary].should eq(true)
  status[:is_active].should eq(true)

  exec(:login)
  should_send("login user pass\n")
  responds("login_success\r\n")
end
