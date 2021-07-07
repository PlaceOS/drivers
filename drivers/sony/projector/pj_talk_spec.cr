require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Projector::PjTalk" do
  resp = exec(:power?)
  should_send("020a534f4e5901010200".hexbytes)
  responds("020a534f4e590101020100".hexbytes)
  resp.get.should eq false
  status[:power].should eq(false)

  exec(:power, true)
  should_send("020a534f4e5900172E00".hexbytes)
  responds("020a534f4e5901172E00".hexbytes)

  should_send("020a534f4e5901010200".hexbytes)
  responds("020a534f4e590101020103".hexbytes)
  status[:power].should eq(true)
end
