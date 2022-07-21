require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Fusion" do
  settings({
    security_level: 0,
    user_id:        "spec-user-id",
    api_pass_code:  "spec-api-pass-code",
    service_url:    "http://spec.example.com/RoomViewSE/APIService/",
    content_type:   "xml",
  })

  resp = exec(:get_rooms, "Meeting Room A")

  expect_http_request do |request, response|
    response.status_code = 200
    response << rooms.to_json
  end

  resp.get

  resp = exec(:get_room, "room-id")

  expect_http_request do |request, response|
    response.status_code = 200
    response << room.to_json
  end

  resp.get
end

private def rooms
  {
    "rooms" => [
      room,
    ],
  }
end

private def room
  {
    "RoomName" => "Meeting Room A",
  }
end
