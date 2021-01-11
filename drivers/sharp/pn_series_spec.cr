DriverSpecs.mock_driver "Sharp::PnSeries" do
  # connected
  # send_credentials
  should_send("\x0D\x0A")
  responds("OK\x0D\x0A")
  should_send("\x0D\x0A")
  responds("Password:Login incorrect\x0D\x0A")

  # Settings can only be accessed after on_load and connected
  settings({
    username: "user",
    password: "pass"
  })

  # Retrying send_credentials
  sleep 5
  should_send("user\x0D\x0A")
  responds("OK\x0D\x0A")
  should_send("pass\x0D\x0A")
  responds("Password:OK\x0D\x0A")
  # do_poll
  should_send("POWR????\x0D\x0A")
  responds("POWR 001\x0D\x0A")
  status[:warming].should eq(false)
  status[:power].should eq(true)
end
