require "placeos-driver/spec"
require "placeos-driver/interface/door_security"

DriverSpecs.mock_driver "Rhombus::SecurityInterop" do
  system({
    SecuritySystem: {DoorSecurityMock},
  })

  settings({
    debug_webhook: true,
    subscriptions: [{
      # spec ports
      webhook: URI.new("http", "127.0.0.1", __get_ports__[1]).to_s,
    }],
  })

  # test notifying of a door event
  timestamp = Time.utc
  exec(:door_event, {
    module_id:       "testing",
    security_system: "testing",
    door_id:         "the-door",
    timestamp:       timestamp.to_unix,
    action:          "RequestToExit",
  }.to_json)

  webhook = nil
  expect_http_request do |request, response|
    webhook = request.body.not_nil!.gets_to_end
    response.status_code = 200
  end

  raise "no webhook payload" unless webhook

  JSON.parse(webhook.not_nil!).should eq({
    "door_id"   => "the-door",
    "timestamp" => timestamp.to_rfc3339,
    "action"    => "request_to_exit",
  })

  # test listing of doors
  resp = exec(:request, "GET", {} of String => Array(String), "").get.not_nil!
  JSON.parse(resp[2].as_s).should eq({
    "doors" => [{
      "door_id" => "testing",
    }],
  })

  # test unlocking a door
  resp = exec(:request, "PUT", {} of String => Array(String), %({"door_id": "some-door"})).get.not_nil!
  resp[0].should eq(200)

  system(:SecuritySystem_1)[:last_unlocked].should eq "some-door"
end

# :nodoc:
class DoorSecurityMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::DoorSecurity

  def door_list : Array(Door)
    [Door.new("testing")]
  end

  def unlock(door_id : String) : Bool?
    self[:last_unlocked] = door_id
    true
  end
end
