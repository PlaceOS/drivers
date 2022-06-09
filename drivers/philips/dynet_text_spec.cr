require "placeos-driver/spec"

DriverSpecs.mock_driver "Philips::DyNetText" do
  # Telnet establishment
  transmit "fffb01".hexbytes
  should_send "fffd01".hexbytes

  transmit "fffd01".hexbytes
  should_send "fffc01".hexbytes

  transmit "fffb03".hexbytes
  should_send "fffd03".hexbytes

  transmit "fffd03".hexbytes
  should_send "fffc03".hexbytes

  transmit "fffb05".hexbytes
  should_send "fffe05".hexbytes

  transmit "fffd05".hexbytes
  should_send "fffc05".hexbytes

  transmit "Telnet Connection Established ...\r\n\r\n"
  sleep 100.milliseconds

  # Configure protocol
  status[:ready].should eq true

  should_send "Echo 0\r\x00"
  responds "OK\r\n"
  should_send "Verbose\r\x00"
  responds "OK\r\n"
  should_send "ReplyOK 1\r\x00"
  responds "OK\r\n"
  should_send "Join 255\r\x00"
  responds "OK\r\n"

  # Process some data
  transmit "Preset 2, Area 103, Fade 0, Join 0xff\r\n"
  sleep 100.milliseconds
  status["area103"].should eq(2)

  # WTF philips, why are there multiple hex representations
  transmit "Channel Level Channel 43, Level 100%, Area 137, Fade 0, Join ffhex\r\n"
  sleep 100.milliseconds
  status["area137_level"].should eq(100)

  # This is a good ping request
  transmit "Date Wed 8 Jun 2022\r\n"
  transmit "Time 13:35:51 Standard Time\r\n"

  # NOTE:: Tests here respond with echos even though we turn this off
  # just for in case the request is ignored

  # Execute some query requests
  resp = exec :get_current_preset, 58
  should_send "RequestCurrentPreset 58\r\x00"
  responds "RequestCurrentPreset 58\r\n"
  responds "OK\r\n"
  # yep, it sometimes replies with a leading null byte, just to screw up anyone dealing with this protocol in C
  responds "\x00Reply with Current Preset 2, Area 58, Join ffhex\r\n"

  resp.get.should eq 2
  status["area58"].should eq(2)

  resp = exec :get_light_level, 58
  should_send "RequestChannelLevel 1 58\r\x00"
  responds "RequestChannelLevel 1 58\r\n"
  responds "OK\r\n"
  responds "Reply with Current Level Ch 1, Area 58, TargLev 100%, CurrLev 100%, Join ffhex\r\n"

  resp.get.should eq 100
  status["area58_level"].should eq(100)

  # Execute some update requests
  resp = exec :trigger, 70, 2, 1000
  should_send "Preset 2 70 1000\r\x00"
  responds "Preset 2 70 1000\r\n"
  responds "OK\r\n"
  responds "Preset 2, Area 70, Fade 1000, Join 0xff\r\n"
  resp.get
  sleep 100.milliseconds
  status["area70"].should eq(2)

  resp = exec :light_level, 70, 90.1, 1000
  should_send "ChannelLevel 0 90 70 1000\r\x00"
  responds "ChannelLevel 0 100 70 1000\r\n"
  responds "OK\r\n"
  responds "Channel Level Channel 0, Level 90%, Area 70, Fade 1000, Join ffhex\r\n"
  resp.get
  sleep 100.milliseconds
  status["area70_level"].should eq(90)

  resp = exec :stop_fading, 70
  should_send "StopFade 0 70\r\x00"
  responds "StopFade 0 70\r\n"
  responds "OK\r\n"
  resp.get

  puts "Test passed!"
end
