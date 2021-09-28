require "placeos-driver/spec"

DriverSpecs.mock_driver "Exterity::AvediaPlayer::R92xx" do
  # this lets the driver know it's successfully connected
  sleep 1
  status[:ready].should eq(false)
  responds("Terminal Control Interface\r")
  status[:ready].should eq(true)

  should_send("^dump!\r").responds %(^currentChannel:udp://239.193.3.169:5000?hwchan=4!
^currentChannel_name:SBS ONE HD!
^currentChannel_number:30!
^currentAVChannel:udp://239.193.3.169:5000?hwchan=4!
^new_channel:NO VALUE!
^cur_channel:udp://239.193.3.169:5000?hwchan=4!)

  status[:cur_channel].should eq "udp://239.193.3.169:5000?hwchan=4"
  status[:current_channel_name].should eq "SBS ONE HD"

  resp = exec(:version)
  responds("^SoftwareVersion:123!\r")
  resp.get
  status[:software_version].should eq("123")

  resp = exec(:tv_info)
  responds("^tv_info:a,b,c,d,e,f,g!\r")
  resp.get
  status[:tv_info].should eq("a,b,c,d,e,f,g")
end
