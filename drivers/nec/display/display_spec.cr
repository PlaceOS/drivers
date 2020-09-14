DriverSpecs.mock_driver "Nec::Display::All" do
  should_send("\x010\x2A0A06\x0201D6\x03\x1F\x0D")
     responds("\x0100\x2AB12\x020200D60000040001\x03\x1F\x0D")
  status[:power].should eq(true)
end