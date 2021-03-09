require "placeos-driver/driver-specs/runner"
require "placeos-driver/driver-specs/mock_driver"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

DriverSpecs.mock_driver "Place::Rooms::Meet" do
  exec(:route, "a", "b").get.should eq("foo")
end
