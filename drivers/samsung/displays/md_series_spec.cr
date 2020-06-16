DriverSpecs.mock_driver "Samsung::Displays::MdSeries" do
  exec(:volume, 24)
  # header + command + id + size + value
  should_send("\xAA\x12\x00\x01\x18")
end