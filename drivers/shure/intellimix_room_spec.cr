require "placeos-driver/spec"

DriverSpecs.mock_driver "Shure::IntellimixRoom" do
  # Test initial connection and device info queries
  should_send("< GET MODEL >").responds "< REP MODEL INTELLIMIX_ROOM >"
  status[:model].should eq("INTELLIMIX_ROOM")

  should_send("< GET FW_VER >").responds "< REP FW_VER 4.7.4 >"
  status[:fw_ver].should eq("4.7.4")

  should_send("< GET DEVICE_ID >").responds "< REP DEVICE_ID IntelliMix_Room_001 >"
  status[:device_id].should eq("IntelliMix_Room_001")

  should_send("< GET ALL >")

  # Test presets
  exec(:get_preset)
  should_send("< GET PRESET >").responds "< REP PRESET 3 >"
  status[:preset].should eq(3)

  exec(:set_preset, 5)
  should_send("< SET PRESET 5 >").responds "< REP PRESET 5 >"
  status[:preset].should eq(5)

  exec(:set_preset, 10)
  should_send("< SET PRESET 10 >").responds "< REP PRESET 10 >"
  status[:preset].should eq(10)

  exec(:get_audio_gain_hi_res, 1)
  should_send("< GET 01 AUDIO_GAIN_HI_RES >").responds "< REP 01 AUDIO_GAIN_HI_RES 1234 >"
  status[:audio_gain_hi_res_01].should eq(1234)
end
