require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Demo::Camera" do
  outp = exec(:power?).get
  puts "EXECUTE: #{outp}"
end
