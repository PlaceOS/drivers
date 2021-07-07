require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Pinger" do
  exec(:ping).get.should eq(true)
  status[:pingable].should eq(true)
end
