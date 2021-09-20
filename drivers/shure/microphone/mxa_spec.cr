require "placeos-driver/spec"

DriverSpecs.mock_driver "Shure::Microphone::MXA" do
  should_send("< GET 0 ALL >").responds "< REP PRESET 10 >"
  status[:preset].should eq(10)

  should_send("< SET METER_RATE 0 >").responds "< REP METER_RATE 0 >"
  status[:meter_rate].should eq(0)

  exec(:query_device_id)
  should_send("< GET DEVICE_ID >").responds "<  REP DEVICE_ID { steves dev } >"
  status[:device_id].should eq("steves dev")
end
