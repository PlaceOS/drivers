require "placeos-driver/spec"

DriverSpecs.mock_driver "Embedia::ControlPoint" do
  exec(:down, 0xFF)
  should_send(":FF060001004E--\r\n")

  exec(:query_sensor, 0xFF)
  should_send(":FF0300010001--\r\n")
  responds(":FF0300010001AA\r\n")
end
