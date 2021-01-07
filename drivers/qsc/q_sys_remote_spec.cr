DriverSpecs.mock_driver "Qsc::QSysRemote" do
  settings({
    username: "user",
    password: "pass"
  })

  exec(:fader, "1", 1, "component")
end
