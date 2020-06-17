  # [header, command, id, size, data]

DriverSpecs.mock_driver "Samsung::Displays::MdSeries" do
  id = "\x00"

  # connected -> do_poll
  # power? will take priority over status as status has priority = 0
  # power? -> panel_mute
  should_send("\xAA\xF9#{id}\x00")
  # status
  should_send("\xAA\x00#{id}\x00")

  exec(:volume, 24)
  should_send("\xAA\x12#{id}\x01\x18")
  # responds("\xAA\xFF\x00\x03\x41\x12Volume")
  # status[:volume].should eq(24)
end