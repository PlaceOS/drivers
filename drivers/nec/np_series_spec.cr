DriverSpecs.mock_driver "Nec::Projector" do
  # # do_poll
  # # power?
  # should_send("\x010*0A06\x0201D6\x03\x1F\x0D")
  # responds("\x0100*B12\x020200D60000040001\x03\x1F\x0D")
  # status[:power].should eq(true)
  # # mute_status
  # should_send("\x010*0C06\x02008D\x03\x12\x0D")
  # responds("\x0100*D12\x0200008D0000000002\x03\x12\x0D")
  # status[:audio_mute].should eq(false)
  # # volume_status
  # should_send("\x010*0C06\x020062\x03\x6A\x0D")
  # responds("\x0100*D12\x020000620000000032\x03\x69\x0D")
  # status[:volume].should eq(50)
  # # video_input
  # should_send("\x010*0C06\x020060\x03\x68\x0D")
  # responds("\x0100*D12\x020000600000000011\x03\x6A\x0D")
  # status[:input].should eq("Hdmi")
  # # audio_input
  # should_send("\x010*0C06\x02022E\x03\x1B\x0D")
  # responds("\x0100*D12\x0200022E0000000001\x03\x18\x0D")
  # status[:audio].should eq("Audio1")

  # exec(:mute_audio)
  # should_send("\x010*0E0A\x02008D0001\x03\x62\x0D")
  # responds("\x0100*F12\x0200008D0000000001\x03\x13\x0D")
  # status[:audio_mute].should eq(true)
  # status[:volume].should eq(0)

  # exec(:unmute_audio)
  # should_send("\x010*0E0A\x02008D0000\x03\x63\x0D")
  # responds("\x0100*F12\x0200008D0000000000\x03\x12\x0D")
  # status[:audio_mute].should eq(false)

  # exec(:volume, 25)
  # should_send("\x010*0E0A\x0200620019\x03\x13\x0D")
  # responds("\x0100*F12\x020000620000640019\x03\x60\x0D")
  # should_send("\x010*0A04\x020C\x03\x1D\x0D")
  # responds("\x0100*B06\x0200C\x03\x2C\x0D")
  # status[:audio_mute].should eq(false)
  # status[:volume].should eq(25)

  # exec(:brightness_status)
  # should_send("\x010*0C06\x020010\x03\x6F\x0D")
  # responds("\x0100*D12\x020000100000000000\x03\x6D\x0D")
  # status[:brightness].should eq(0)

  # exec(:brightness, 100)
  # should_send("\x010*0E0A\x0200100064\x03\x1C\x0D")
  # responds("\x0100*F12\x020000100000640064\x03\x6F\x0D")
  # should_send("\x010*0A04\x020C\x03\x1D\x0D")
  # responds("\x0100*B06\x0200C\x03\x2C\x0D")
  # status[:brightness].should eq(100)

  # exec(:switch_to, "tv")
  # should_send("\x010*0E0A\x020060000A\x03\x68\x0D")
  # responds("\x0100*F12\x02000060000000000A\x03\x19\x0D")
  # status[:input].should eq("Tv")

  # exec(:switch_audio, "audio_2")
  # sleep 6 # since switch_to has 6 seconds of delay
  # should_send("\x010*0E0A\x02022E0002\x03\x68\x0D")
  # responds("\x0100*F12\x0200022E0000000002\x03\x19\x0D")
  # status[:audio].should eq("Audio2")

  # exec(:power, false)
  # should_send("\x010*0A0C\x02C203D60004\x03\x1D\x0D")
  # responds("\x0100*B0E\x0200C203D60004\x03\x18\x0D")
  # status[:power].should eq(false)
end
