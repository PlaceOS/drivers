  # [header, command, id, data.size, [data], checksum]

DriverSpecs.mock_driver "Samsung::Displays::MdSeries" do
  id = "\x00"

  # connected -> do_poll
  # power? will take priority over status as status has priority = 0
  # power? -> panel_mute
  should_send("\xAA\xF9#{id}\x00\xF9")
  responds("\xAA\xFF#{id}\x03A\xF9\x00\x3C")
  # status
  should_send("\xAA\x00#{id}\x00\x00")
  responds("\xAA\xFF#{id}\x09A\x00\x00\x06\x00\x14\x00\x00\x00\x63")

  exec(:volume, 24)
  should_send("\xAA\x12#{id}\x01\x18\x2B")
  responds("\xAA\xFF\x00\x03A\x12\x18")
  # status[:volume].should eq(24)
end