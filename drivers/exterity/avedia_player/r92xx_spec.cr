DriverSpecs.mock_driver "Exterity::AvediaPlayer::R92xx" do

  # this lets the driver know it's successfully connected
  responds("Exterity Control Interface!")

  exec(:version)
  responds("^SoftwareVersion:123!")
  status[:version].should eq("123")

  exec(:tv_info)
  responds("^tv_info:a,b,c,d,e,f,g!")
  sleep(1)
  status[:tv_info].should eq("a,b,c,d,e,f,g")


end
