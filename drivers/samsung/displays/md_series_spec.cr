DriverSpecs.mock_driver "Samsung::Displays::MdSeries" do
  exec(:volume, 24)
  # header + command + id + size + value
  should_send("\xAA\x12\x00\x01\x18")
  #responds("\xAA\xFF\x00\x03\x41\x12Volume")
  #status[:volume].should eq(24)
end