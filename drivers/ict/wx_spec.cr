require "placeos-driver/spec"

DriverSpecs.mock_driver "Ict::Wx" do
  exec(:get_session_key).get.should eq(123)
end
