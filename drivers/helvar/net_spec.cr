require "placeos-driver/spec"

DriverSpecs.mock_driver "Helvar::Net" do
  # Perform actions
  resp = exec(:trigger, group: 1, scene: 2, fade: 1100)
  should_send(">V:2,C:11,G:1,S:2,F:110#")
  responds(">V:2,C:11,G:1,S:2,F:110,A:1#")
  resp.get
  status[:area1].should eq(2)

  resp = exec(:get_current_preset, group: 17)
  should_send(">V:2,C:109,G:17#")
  responds("?V:2,C:109,G:17=14#")
  resp.get.should eq 14
  status[:area17].should eq(14)

  resp = exec(:get_current_preset, group: 20)
  should_send(">V:2,C:109,G:20#")
  responds("!V:2,C:109,G:20=1#")
  expect_raises(PlaceOS::Driver::RemoteException, "invalid group index parameter for !V:2,C:109,G:20=1 (Abort)") do
    resp.get
  end
  status[:last_error].should eq("invalid group index parameter for !V:2,C:109,G:20=1")

  transmit(">V:2,C:11,G:2001,B:1,S:1,F:100#")
  status[:area2001].should eq(1)

  resp = exec(:lighting_level?, area: {id: 17})
  should_send(">V:2,C:109,G:17#")
  responds("?V:2,C:109,G:17=1#")
  should_send(">V:2,C:167,G:17#")
  responds("?V:2,C:167,G:17=100,75,50,25,0,L,L,L,0,*,*,*,*,*#")
  resp.get.should eq 75
  status[:area17_level].should eq(75)
end
