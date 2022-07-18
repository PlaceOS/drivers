require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Fusion" do
    settings({
        security_level: 0,
        user_id: "spec-user-id",
        api_pass_code: "spec-api-pass-code",
        service_url: "http://spec.example.com/RoomViewSE/APIService/",
        content_type: "xml",
  })


end
