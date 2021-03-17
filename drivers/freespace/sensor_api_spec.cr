require "json"
require "stomp"

DriverSpecs.mock_driver "Freespace::SensorAPI" do
  # ===========
  # Negotiation
  # ===========

  client = STOMP::Client.new("127.0.0.1")
  should_send(client.stomp.to_s)

  connect_message = STOMP::Frame.new(STOMP::Command::Connected, HTTP::Headers{
    "version" => "1.2",
    # server sends a blank heartbeat
    "heart-beat" => "0,0"
  })
  responds(connect_message.to_s)

  # ==========
  # GET SPACES
  # ==========

  expect_http_request do |request, response|
    headers = request.headers
    io = request.body
    if io = request.body
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["username"] == "user" && request["password"] == "pass"
        response.status_code = 200
        response.headers["X-Auth-Key"] = "12345"
      else
        response.status_code = 401
      end
    else
      raise "expected request to include dialing details #{request.inspect}"
    end
  end

  expect_http_request do |request, response|
    headers = request.headers

    if headers["X-Auth-Key"]? == "12345"
      response.status_code = 200
      response.output.puts SPACES_RESPONSE
    else
      response.status_code = 401
    end
  end

  # =============
  # Subscriptions
  # =============

  should_send(client.subscribe("space-96978", "/topic/spaces/96978/activities", HTTP::Headers{
    "receipt" => "rec-96978",
  }).to_s)

  # ==========
  # GET TOKEN
  # ==========

  # cached
  retval = exec(:get_token)
  retval.get.should eq("12345")

  # =============
  # Status update
  # =============
  time_now = Time.utc.to_unix
  status_update = STOMP::Frame.new(STOMP::Command::Message, HTTP::Headers{
    "subscription" => "space-96978",
    "destination" => "/topic/spaces/96978/activities"
  }, {
    id: 1234,
    spaceId: 96978,
    utcEpoch: time_now,
    state: 1
  }.to_json)

  transmit status_update.to_s

  status["space-96978"].should eq({
    "location" => 775,
    "name" => "WS7-01",
    "capacity" => 1,
    "count" => 1,
    "last_updated" => time_now,
  })

  # =================
  # location services
  # =================
  exec(:device_locations, "zone-building").get.should eq([{
    "location" => "desk",
    "at_location" => 1,
    "map_id" => "WS7-01",
    "level" => "zone-level",
    "building" => "zone-building",
    "capacity" => 1,
  }])
end

SPACES_RESPONSE = [{ "id" => 96978,
  "location" => {"id" => 775, "scalingFactor" => nil, "raw" => true, "policy" => true},
  "name" => "WS7-01",
  "srf" => {"x" => 91, "y" => 2169, "z" => 0},
  "marker" => {"type" => "CIRCLE", "data" => "20"},
  "category" => {"id" => 297,
    "name" => "Assigned Desks",
    "shortName" => nil,
    "showOnSignage" => false,
    "showInAnalytics" => true,
    "iconUrl" => nil,
    "colorScheme" => "#ffb3b3",
    "orderingIndex" => 113},
  "sensingPolicyId" => 247,
  "department" => {"id" => 498,
    "name" => "Sales",
    "shortName" => nil,
    "showOnSignage" => false,
    "showInAnalytics" => false,
    "colorScheme" => nil,
    "orderingIndex" => nil},
  "subCategory" => {"id" => 194,
    "name" => "None",
    "shortName" => nil,
    "showOnSignage" => false,
    "showInAnalytics" => false,
    "colorScheme" => nil,
    "orderingIndex" => 194},
  "device" => {"id" => 2016090160,
    "displayName" => "1609010160",
    "updatedAt" => nil,
    "floorId" => nil,
    "shape" => nil,
    "coord" => nil,
    "blessId" => 1609010160,
    "blessQr" => nil,
    "accessedAt" => "2021-03-11T08:06:01.000+0000",
    "installedOn" => nil,
    "licenseeId" => nil,
    "hardware" => nil,
    "network" => nil,
    "itemId" => nil},
  "markerUniqueId" => "K_2493713878097_18542",
  "live" => false,
  "capacity" => 1,
  "counter" => "NO_COUNTER",
  "serial" => 1,
  "locationId" => 775,
  "counted" => true
}].to_json
