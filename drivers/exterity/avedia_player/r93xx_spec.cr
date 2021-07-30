require "placeos-driver/spec"

DriverSpecs.mock_driver "Exterity::AvediaPlayer::R92xx" do
  responds("login:")
  should_send("admin\r\n", 3.seconds)
  should_send("labrador\r\n", 3.seconds)

  # this lets the driver know it's successfully connected
  status[:ready].should eq(false)
  responds("Terminal Control Interface\r")

  status[:ready].should eq(true)

  exec(:version)
  responds("^SoftwareVersion:123!\r")

  status[:version].should eq("123")

  exec(:tv_info)
  responds("^tv_info:a,b,c,d,e,f,g!\r")

  status[:tv_info].should eq("a,b,c,d,e,f,g")
end
