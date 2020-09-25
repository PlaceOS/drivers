DriverSpecs.mock_driver "Nec::Display::All" do
  # do_poll
  # power?
  should_send("\x010*0A06\x0201D6\x03\x1F\x0D")
     responds("\x0100*B12\x020200D60000040004\x03\x1A\x0D")
  status[:power].should eq(false)

  exec(:power, true)
  should_send("\x010*0A0C\x02C203D60001\x03\x18\x0D")
     responds("\x0100*B0E\x0200C203D60001\x03\x1D\x0D")
  status[:power].should eq(true)
end
