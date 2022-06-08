require "placeos-driver/spec"

DriverSpecs.mock_driver "Philips::DyNetText" do
  # Telnet establishment
  transmit "fffb01".hexbytes
  transmit "fffd01fffb03fffd03fffb05fffd05".hexbytes
  transmit "Telnet Connection Established ...\r\n\r\n"

  sleep 200.milliseconds
  status[:ready].should eq true

  # Process some data
  transmit "Preset 2, Area 103, Fade 0, Join 0xff\r\n"

  # WTF philips, why are there multiple hex representations
  transmit "Channel Level Channel 43, Level 100%, Area 137, Fade 0, Join ffhex\r\n"

  # This is a good ping request
  transmit "Date Wed 8 Jun 2022\r\n"

  transmit "Time 13:35:51 Standard Time\r\n"

  # Execute some requests
  resp = exec :get_current_preset, 58
  should_send "RequestCurrentPreset 58\r\x00"
  responds "RequestCurrentPreset 58\r\n"
  responds "OK\r\n"
  responds "Reply with Current Preset 2, Area 58, Join ffhex\r\n"

  resp.get.should eq 2
  status["area58"].should eq(2)

  resp = exec :get_light_level, 58
  should_send "RequestChannelLevel 1 58\r\x00"
  responds "RequestChannelLevel 1 58\r\n"
  responds "OK\r\n"
  responds "Reply with Current Level Ch 1, Area 58, TargLev 100%, CurrLev 100%, Join ffhex\r\n"

  resp.get.should eq 100
  status["area58_level"].should eq(100)
end
