require "placeos-driver/spec"

DriverSpecs.mock_driver "Ict::Tester" do
  resp = exec(:get_api_key)
  resp.get.should eq("BLAH")
end
