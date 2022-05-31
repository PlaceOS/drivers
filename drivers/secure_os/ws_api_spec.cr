require "placeos-driver/spec"
require "./ws_api_models"

private macro respond_with(code, body)
  res.headers["Content-Type"] = "application/json"
  res.status_code = {{code}}
  res.output << {{body}}
end

DriverSpecs.mock_driver "SecureOS::WsApi" do
  # Getting WebSocket auth token
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/ws_auth")
    req.headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("srvc_acct:password!")}")
    respond_with 200, {data: {token: "qwertyuio"}, status: :success}.to_json
  end
  should_send({type: :auth, token: "qwertyuio"}.to_json)

  # Getting a list of cameras
  camera = {
    "id"       => "1",
    "name"     => "Camera 1",
    "settings" => {"telemetry_id" => "native"},
    "status"   => {
      "enabled" => true,
      "state"   => "DISARMED",
    },
    "type" => "CAM",
  }
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/cameras")
    req.headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("srvc_acct:password!")}")
    respond_with 200, {
      data:   [camera],
      status: "success",
    }.to_json
  end
  status[:camera_list].should eq([camera])

  # Subscribing to states/events
  should_send({
    type: :subscribe,
    data: {
      add_rules: [
        {
          type:   "CAM",
          id:     "1",
          states: [
            SecureOS::StateType::Attached,
            SecureOS::StateType::Armed,
            SecureOS::StateType::Alarmed,
          ],
          action: :STATE_CHANGED,
        },
        {
          type:   "CAM",
          id:     "1",
          action: :EVENT,
        },
      ],
    },
  }.to_json)

  # Getting a list of watchlists
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/watchlists")
    req.headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("srvc_acct:password!")}")
    respond_with 200, {
      data: [
        {id: "1", name: "some list"},
      ],
      status: "success",
    }.to_json
  end
  status[:camera_list].should eq([camera])

  # Adding a license plate to a watchlist
  exec(:watchlist_add_lp, watchlist: "some list", license_plate: "ABC", comment: "Test plate")
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/api/v1/watchlists/1/set")
    req.headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("srvc_acct:password!")}")
    req.headers["Content-Type"]?.should eq("application/json")
    respond_with 200, "Comment for number ABC has been set."
  end

  # Removing a license plate from a watchlist
  exec(:watchlist_remove_lp, watchlist: "some list", license_plate: "ABC")
  expect_http_request do |req, res|
    req.method.should eq("POST")
    req.path.should eq("/api/v1/watchlists/1/delete")
    req.headers["Authorization"]?.should eq("Basic #{Base64.strict_encode("srvc_acct:password!")}")
    req.headers["Content-Type"]?.should eq("application/json")
    respond_with 200, "Number ABC has been deleted from the watchlist."
  end

  # Recieving states
  states = {
    "type"   => "CAM",
    "id"     => "1",
    "ticks"  => 501234,
    "time"   => "2017-02-02T16:10:07.241",
    "states" => {
      "attached" => true,
      "armed"    => true,
      "alarmed"  => false,
    },
  }
  transmit({
    type: :state,
    data: states,
  }.to_json)
  status[:camera_1_states].should eq(states)

  # Recieving events
  event = {
    "type"       => "CAM",
    "id"         => "1",
    "action"     => "CAR_LP_RECOGNIZED",
    "ticks"      => 501234,
    "time"       => "2017-02-02T16:10:07.241",
    "parameters" => {
      "camera_id"       => "6",
      "direction_name"  => "approaching",
      "number"          => "T345 LYW",
      "recognizer_id"   => "1",
      "recognizer_type" => "LPR_CAM",
    },
  }
  transmit({
    type: :event,
    data: event,
  }.to_json)
  status[:camera_1].should eq(event)

  # A delete event is sent if a subscribed camera is removed
  transmit({
    type: :event,
    data: {
      type:   :CAM,
      id:     "1",
      action: :DELETED,
      time:   "2017-02-02T16:10:07.241",
    },
  }.to_json)
  status[:camera_1]["parameters"]?.should be_nil
end
