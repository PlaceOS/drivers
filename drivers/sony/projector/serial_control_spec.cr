DriverSpecs.mock_driver "Sony::Projector::SerialControl" do
  exec(:power, false)
  sleep 3
  should_send("\xA9\x17\x2F\x00\x00\x00\x3F\x9A")
  should_send("\xA9\x01\x02\x01\x00\x00\x03\x9A")
  responds("\xA9\x01\x02\x02\x00\x04\xFF\x9A")
  status[:cooling].should eq(true)
  status[:warming].should eq(false)
  status[:power].should eq(false)
end
