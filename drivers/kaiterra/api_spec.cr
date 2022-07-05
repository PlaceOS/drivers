require "placeos-driver/spec"

DriverSpecs.mock_driver "Kaiterra::API" do
  exec(:get_request, "test", "Us")
end
