require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Fusion" do
  before_all do
    settings({
      security_level: 0,
      user_id:        "spec-user-id",
      api_pass_code:  "spec-api-pass-code",
      service_url:    "http://spec.example.com/RoomViewSE/APIService/",
      content_type:   "xml",
    })
  end

  before_each do
    pp "========================================"
  end

  it "returns rooms" do
    resp = exec(:get_rooms, "Meeting Room A")

    expect_http_request do |request, response|
      pp request

      response.status_code = 200
      response << rooms_json_response
    end

    # resp.get
  end

  it "returns a room" do
    resp = exec(:get_room, "room-id")

    expect_http_request do |request, response|
      pp request

      response.status_code = 200
      response << room_json_response
    end

    # resp.get
  end
end

private def rooms_json_response
  {
    rooms: [
      get_room,
    ],
  }.to_json
end

private def room_json_response
  get_room.to_json
end

private def get_room
  room = Room.new
  room.room_name = "Meeting Room A"
  room
end
