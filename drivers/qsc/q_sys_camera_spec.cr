require "placeos-driver/spec"

DriverSpecs.mock_driver "Qsc::QSysCamera" do
  exec(:power, true)

  exec(:adjust_tilt, "up")
  exec(:adjust_tilt, "")
  exec(:adjust_pan, "right")
  exec(:adjust_pan, "")

  exec(:home)
  exec(:power, false)
  end
