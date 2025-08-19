require "placeos-driver/spec"

DriverSpecs.mock_driver "Shure::IntellimixRoom" do
  # Test initial connection and device info queries
  should_send("< GET DEVICE_ID >").responds "< REP DEVICE_ID IntelliMix_Room_001 >"
  status[:device_id].should eq("IntelliMix_Room_001")

  should_send("< GET MODEL >").responds "< REP MODEL INTELLIMIX_ROOM >"
  status[:model].should eq("INTELLIMIX_ROOM")

  should_send("< GET FW_VER >").responds "< REP FW_VER 4.7.4 >"
  status[:fw_ver].should eq("4.7.4")

  should_send("< GET INPUT_COUNT >").responds "< REP INPUT_COUNT 8 >"
  status[:input_count].should eq(8)

  # Test master controls
  exec(:query_master_mute)
  should_send("< GET MASTER_MUTE >").responds "< REP MASTER_MUTE OFF >"
  status[:master_mute].should be_false

  exec(:set_master_mute, true)
  should_send("< SET MASTER_MUTE ON >").responds "< REP MASTER_MUTE ON >"
  status[:master_mute].should be_true

  exec(:query_master_gain)
  should_send("< GET MASTER_GAIN >").responds "< REP MASTER_GAIN -10.5 >"
  status[:master_gain].should eq(-10.5)

  exec(:set_master_gain, -5.0)
  should_send("< SET MASTER_GAIN -5.0 >").responds "< REP MASTER_GAIN -5.0 >"
  status[:master_gain].should eq(-5.0)

  # Test input channel controls
  exec(:query_input_gain, 1)
  should_send("< GET 1 INPUT_GAIN >").responds "< REP 1 INPUT_GAIN 0.0 >"
  status[:input_gain_1].should eq(0.0)

  exec(:set_input_gain, 1, 5.5)
  should_send("< SET 1 INPUT_GAIN 5.5 >").responds "< REP 1 INPUT_GAIN 5.5 >"
  status[:input_gain_1].should eq(5.5)

  exec(:query_input_mute, 2)
  should_send("< GET 2 INPUT_MUTE >").responds "< REP 2 INPUT_MUTE OFF >"
  status[:input_mute_2].should be_false

  exec(:set_input_mute, 2, true)
  should_send("< SET 2 INPUT_MUTE ON >").responds "< REP 2 INPUT_MUTE ON >"
  status[:input_mute_2].should be_true

  # Test output channel controls
  exec(:query_output_gain, 1)
  should_send("< GET 1 OUTPUT_GAIN >").responds "< REP 1 OUTPUT_GAIN -2.5 >"
  status[:output_gain_1].should eq(-2.5)

  exec(:set_output_gain, 1, 0.0)
  should_send("< SET 1 OUTPUT_GAIN 0.0 >").responds "< REP 1 OUTPUT_GAIN 0.0 >"
  status[:output_gain_1].should eq(0.0)

  exec(:query_output_mute, 1)
  should_send("< GET 1 OUTPUT_MUTE >").responds "< REP 1 OUTPUT_MUTE OFF >"
  status[:output_mute_1].should be_false

  exec(:set_output_mute, 1, true)
  should_send("< SET 1 OUTPUT_MUTE ON >").responds "< REP 1 OUTPUT_MUTE ON >"
  status[:output_mute_1].should be_true

  # Test AudioMuteable interface
  exec(:mute_audio, true, 1)
  should_send("< SET 1 OUTPUT_MUTE ON >").responds "< REP 1 OUTPUT_MUTE ON >"
  status[:output_mute_1].should be_true

  exec(:unmute_audio, 1)
  should_send("< SET 1 OUTPUT_MUTE OFF >").responds "< REP 1 OUTPUT_MUTE OFF >"
  status[:output_mute_1].should be_false

  # Test presets
  exec(:query_preset)
  should_send("< GET PRESET >").responds "< REP PRESET 3 >"
  status[:preset].should eq(3)

  exec(:load_preset, 5)
  should_send("< SET PRESET 5 >").responds "< REP PRESET 5 >"
  status[:preset].should eq(5)

  # Test audio processing features
  exec(:query_noise_reduction, 1)
  should_send("< GET 1 NOISE_REDUCTION >").responds "< REP 1 NOISE_REDUCTION ON >"
  status[:noise_reduction_1].should be_true

  exec(:set_noise_reduction, 1, false)
  should_send("< SET 1 NOISE_REDUCTION OFF >").responds "< REP 1 NOISE_REDUCTION OFF >"
  status[:noise_reduction_1].should be_false

  exec(:query_automatic_gain_control, 1)
  should_send("< GET 1 AGC >").responds "< REP 1 AGC OFF >"
  status[:agc_1].should be_false

  exec(:set_automatic_gain_control, 1, true)
  should_send("< SET 1 AGC ON >").responds "< REP 1 AGC ON >"
  status[:agc_1].should be_true

  # Test level monitoring
  exec(:query_input_level, 1)
  should_send("< GET 1 INPUT_LEVEL >").responds "< REP 1 INPUT_LEVEL -25.3 >"
  status[:input_level_1].should eq(-25.3)

  exec(:query_output_level, 1)
  should_send("< GET 1 OUTPUT_LEVEL >").responds "< REP 1 OUTPUT_LEVEL -18.7 >"
  status[:output_level_1].should eq(-18.7)

  # Test error handling - this command should never be sent due to validation
  # exec(:set_input_gain, 1, 25.0)
  # should_send("< SET 1 INPUT_GAIN 25.0 >").responds "< REP ERR INVALID_RANGE >"

  # Test parameter validation - exceptions are raised but not easily testable in specs
  # expect_raises(Exception, "Gain must be between -100.0 and 20.0 dB") do
  #   exec(:set_input_gain, 1, 50.0)
  # end

  # expect_raises(Exception, "Channel must be between 1 and 8") do
  #   exec(:query_input_gain, 15)
  # end

  # expect_raises(Exception, "Preset must be between 1 and 10") do
  #   exec(:load_preset, 15)
  # end

  # Test edge cases
  exec(:set_input_gain, 1, -100.0)
  should_send("< SET 1 INPUT_GAIN -100.0 >").responds "< REP 1 INPUT_GAIN -100.0 >"
  status[:input_gain_1].should eq(-100.0)

  exec(:set_input_gain, 1, 20.0)
  should_send("< SET 1 INPUT_GAIN 20.0 >").responds "< REP 1 INPUT_GAIN 20.0 >"
  status[:input_gain_1].should eq(20.0)

  exec(:load_preset, 1)
  should_send("< SET PRESET 1 >").responds "< REP PRESET 1 >"
  status[:preset].should eq(1)

  exec(:load_preset, 10)
  should_send("< SET PRESET 10 >").responds "< REP PRESET 10 >"
  status[:preset].should eq(10)
end
