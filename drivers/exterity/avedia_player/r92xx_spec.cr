require "placeos-driver/spec"

DriverSpecs.mock_driver "Exterity::AvediaPlayer::R92xx" do
  responds("login:")
  should_send("admin\r\n")
  should_send("labrador\r\n")
  should_send("6\r\n")
  should_send("/usr/bin/serialCommandInterface\r\n", 20.seconds)
  # this lets the driver know it's successfully connected

  status[:ready].should eq(false)
  responds("Exterity Control Interface\r")

  status[:ready].should eq(true)

  exec(:version)
  responds("^SoftwareVersion:123!\r")

  status[:version].should eq("123")

  exec(:tv_info)
  responds("^tv_info:a,b,c,d,e,f,g!\r")

  status[:tv_info].should eq("a,b,c,d,e,f,g")
end
