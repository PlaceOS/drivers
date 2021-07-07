require "placeos-driver/driver-specs/runner"

# [header, command, id, data.size, [data], checksum]

DriverSpecs.mock_driver "Samsung::Displays::MDCProtocol" do
  id = "\x00"

  # connected -> do_poll
  # power? will take priority over status as status has priority = 0
  # power? -> panel_mute
  should_send("\xAA\xF9#{id}\x00\xF9")
  responds("\xAA\xFF#{id}\x03A\xF9\x00\x3C")
  status[:power].should eq(true)
  # status
  should_send("\xAA\x00#{id}\x00\x00")
  responds("\xAA\xFF#{id}\x09A\x00\x01\x06\x00\x14\x00\x00\x00\x64")
  status[:hard_off].should eq(false)
  status[:power].should eq(true)
  status[:volume].should eq(6)
  status[:audio_mute].should eq(false)
  status[:input].should eq("Vga")

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
  # Video mute
  should_send("\xAA\xF9#{id}\x01\x01\xFB")
  responds("\xAA\xFF#{id}\x03A\xF9\x01\x3D")
  status[:power].should eq(false)
  # Audio mute
  should_send("\xAA\x12#{id}\x01\x00\x13")
  responds("\xAA\xFF\x00\x03A\x12\x00\x55")
  status[:audio_mute].should eq(true)
  status[:volume].should eq(0)

  exec(:unmute)
  # Video unmute
  should_send("\xAA\xF9#{id}\x01\x00\xFA")
  responds("\xAA\xFF#{id}\x03A\xF9\x00\x3C")
  status[:power].should eq(true)
  # Audio unmute
  should_send("\xAA\x12#{id}\x01\x06\x19")
  responds("\xAA\xFF#{id}\x03A\x12\x06\x5B")
  status[:audio_mute].should eq(false)
  status[:volume].should eq(6)

  exec(:switch_to, "hdmi")
  should_send("\xAA\x14#{id}\x01\x21\x36")
  responds("\xAA\xFF#{id}\x03A\x14\x21\x78")
  status[:input].should eq("Hdmi")

  # power(false) == video_mute(true)
  exec(:power, false)
  should_send("\xAA\xF9#{id}\x01\x01\xFB")
  responds("\xAA\xFF#{id}\x03A\xF9\x01\x3D")
  status[:power].should eq(false)
end
