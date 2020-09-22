  # [header, command, id, data.size, [data], checksum]

DriverSpecs.mock_driver "Samsung::Displays::MDCProtocol" do
  id = "\x00"

  # connected -> do_poll
  # power? will take priority over status as status has priority = 0
  # power? -> panel_mute
  should_send("\xAA\xF9#{id}\x00\xF9")
  responds("\xAA\xFF#{id}\x03A\xF9\x00\xFF")
  status[:power].should eq(true)
  # status
  should_send("\xAA\x00#{id}\x00\x00")
  responds("\xAA\xFF#{id}\x09A\x00\x01\x06\x00\x14\x00\x00\x00\xFF")
  status[:hard_off].should eq(false)
  status[:power].should eq(true)
  status[:volume].should eq(6)
  status[:audio_mute].should eq(false)
  status[:input].should eq("Vga")

  exec(:volume, 24)
  should_send("\xAA\x12#{id}\x01\x18\x12")
  responds("\xAA\xFF\x00\x03A\x12\x18\xFF")
  status[:volume].should eq(24)
  status[:audio_mute].should eq(false)

  exec(:mute, true)
  responds("\xAA\xFF#{id}\x03A\xF9\x01\xFF")
  status[:power].should eq(false)

  exec(:unmute)
  responds("\xAA\xFF#{id}\x03A\xF9\x00\xFF")
  status[:power].should eq(true)
end
