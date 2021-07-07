require "placeos-driver/spec"

DriverSpecs.mock_driver "Denon::Amplifier::AvReceiver" do
  ####
  # POWER
  #
  sleep 1.second
  # query power
  exec(:power?)
  should_send("PW?")
  responds("PWOFF\r")
  status[:power].should eq("OFF")
  # turn power on
  exec(:power, true)
  should_send("PWON")
  responds("PWON\r")
  status[:power].should eq("ON")
  # power off turns amp to STANDBY not actually OFF
  exec(:power, false)
  should_send("PWSTANDBY")
  responds("PWSTANDBY\r")
  status[:power].should eq("STANDBY")

  ####
  # INPUT
  #
  sleep 1.second
  # query input > DVD
  exec(:input?)
  should_send("SI?")
  responds("SIDVD\r")
  status[:input].should eq("DVD")
  # chaange input to tuner
  exec(:input, "TUNER")
  should_send("SITUNER")
  responds("SITUNER\r")
  status[:input].should eq("TUNER")

  ####
  # VOLUME
  #
  sleep 1.second
  # query
  exec(:volume?)
  should_send("MV?")
  responds("MV80\r")
  status[:volume].should eq("80")
  # change volume
  exec(:volume, 78)
  should_send("MV39.0")
  responds("MV39.0\r")
  status[:volume].should eq("39.0")

  ####
  # MUTE
  #
  sleep 1.second
  # query
  exec(:mute?)
  should_send("MU?")
  responds("MUOFF\r")
  status[:mute].should eq("OFF")
  # mute on
  exec(:mute, true)
  should_send("MUON")
  responds("MUON\r")
  status[:mute].should eq("ON")
  # mute off
  exec(:mute, false)
  should_send("MUOFF")
  responds("MUOFF\r")
  status[:mute].should eq("OFF")
end
