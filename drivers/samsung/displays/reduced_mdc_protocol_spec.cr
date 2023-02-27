require "placeos-driver/spec"

# [header, command, id, data.size, [data], checksum]

DriverSpecs.mock_driver "Samsung::Displays::ReducedMDCProtocol" do
  id = "\x00"

  # connected -> do_poll
  # power? will take priority over status as status has priority = 0
  # power? -> panel_mute
  should_send("\xAA\x11#{id}\x00\x11")
  responds("\xAA\xFF#{id}\x03A\x11\x00\x54")
  status[:power].should eq(false)

  exec(:power, true)
  should_send("\xAA\x11#{id}\x01\x01\x13")
  responds("\xAA\xFF#{id}\x03A\x11\x01\x55")
  status[:power].should eq(true)

  exec(:volume, 24)
  should_send("\xAA\x12#{id}\x01\x18\x2B")
  responds("\xAA\xFF#{id}\x03A\x12\x18\x6D")
  status[:volume].should eq(24)
  status[:audio_mute].should eq(false)

  exec(:volume, 6)
  should_send("\xAA\x12#{id}\x01\x06\x19")
  responds("\xAA\xFF#{id}\x03A\x12\x06\x5B")
  status[:volume].should eq(6)
  status[:audio_mute].should eq(false)

  exec(:mute)
  # Audio mute
  should_send("\xAA\x12#{id}\x01\x00\x13")
  responds("\xAA\xFF\x00\x03A\x12\x00\x55")
  status[:audio_mute].should eq(true)
  status[:volume].should eq(0)

  exec(:unmute)
  # Audio unmute
  should_send("\xAA\x12#{id}\x01\x06\x19")
  responds("\xAA\xFF#{id}\x03A\x12\x06\x5B")
  status[:audio_mute].should eq(false)
  status[:volume].should eq(6)

  exec(:switch_to, "hdmi")
  should_send("\xAA\x14#{id}\x01\x21\x36")
  responds("\xAA\xFF#{id}\x03A\x14\x21\x78")
  status[:input].should eq("Hdmi")
end
