require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Biamp::Tesira" do
  transmit "login: "
  should_send "default\r\n"
  should_send "default\r\n"
  should_send "SESSION set verbose false\r\n"

  exec(:preset, 1001)
  should_send "DEVICE recallPreset 1001"

  exec(:preset, "1001-test")
  should_send "DEVICE recallPresetByName 1001-test"

  exec(:start_audio)
  should_send "DEVICE startAudio"

  exec(:reboot)
  should_send "DEVICE reboot"

  exec(:get_aliases)
  should_send "SESSION get aliases"

  exec(:mixer, "123", [1])
  should_send "123 set crosspointLevelState 1 false"

  exec(:fader, "Fader123", 11)
  should_send "Fader123 set level 1 11"
  responds("+OK\r\n")
  status["level_Fader123_1"] = 11

  exec(:mute, "Fader123")
  should_send "Fader123 set mute 1 true"
  responds("+OK\r\n")
  status["level_Fader123_1_mute"] = true

  exec(:query_fader, "Fader123")
  should_send "Fader123 get level 1"
end
