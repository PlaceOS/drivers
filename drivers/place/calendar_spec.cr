require "placeos-driver/spec"

# this spec isn't implemented as this driver wraps an independently tested library
# however sometimes it is useful to run tests here.
#
# To run specs, add proper credentials to the drivers settings
# then you can check the responses here
DriverSpecs.mock_driver "Place::Calendar" do
  # exec(:get_members, "SalesandMarketing@0cbfs.onmicrosoft.com").get
  # sleep 1
end
