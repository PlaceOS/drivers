require "placeos-driver/spec"

private macro respond_with(code, body)
  res.headers["Content-Type"] = "application/json"
  res.status_code = {{code}}
  res.output << {{body}}
end

DriverSpecs.mock_driver "Juniper::MistWebsocket" do
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/sites/site_id/maps")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with(200, %([]))
  end

  # sync on connect
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/sites/site_id/maps")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with(200, %([{
      "name": "Level 8",
      "id": "map_id",
      "type": "image",
      "url": "https://api.mist.com/api/v1/forward/download?jwt=eyJ0eXAo",
      "thumbnail_url": "https://api.mist.com/api/v1/forward/download?jwt=ey6k",
      "site_id": "site_id",
      "org_id": "org_id",
      "width": 1040,
      "height": 1804,
      "width_m": 20.8,
      "height_m": 36.08,
      "created_time": 1718259348,
      "modified_time": 1718751847
    }]))
  end

  # sync on connect
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/sites/site_id/stats/maps/map_id/clients")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with 200, "[]"
  end

  client = exec(:client, "5684dae9ac8b")
  client_data = %({
    "mac": "5684dae9ac8b",
    "last_seen": 1470417522,

    "username": "david@mist.com",
    "hostname": "David-Macbook",
    "os": "OS X 10.10.2",
    "manufacture": "Apple",
    "family": "iPhone",
    "model": "6S",

    "ip": "192.168.1.8",

    "ap_mac": "5c5b35000010",
    "ap_id": "0000000-0000-0000-1000-5c5b35000010",
    "ssid": "corporate",
    "wlan_id": "be22bba7-8e22-e1cf-5185-b880816fe2cf",
    "psk_id": "732daf4e-f51e-8bba-06f9-b25cd0e779ea",

    "uptime": 3568,
    "idle_time": 3,
    "power_saving": true,
    "band": "24",
    "proto": "a",
    "key_mgmt": "WPA2-PSK/CCMP",
    "dual_band": false,

    "channel": 7,
    "vlan_id": "",
    "airespace_ifname": "",
    "rssi": -65,
    "snr": 31,
    "tx_rate": 65,
    "rx_rate": 65,

    "tx_bytes": 175132,
    "tx_bps": 6,
    "tx_packets": 1566,
    "tx_retries": 500,
    "rx_bytes": 217416,
    "rx_bps": 12,
    "rx_packets": 2337,
    "rx_retries": 5,

    "map_id": "63eda950-c6da-11e4-a628-60f81dd250cc",
    "x": 53.5,
    "y": 173.1,
    "num_locating_aps": 3,
    "accuracy": 2,

    "is_guest": false
  })
  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/sites/site_id/stats/clients/5684dae9ac8b")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with 200, client_data
  end
  client = client.get.not_nil!
  client.should eq(JSON.parse(client_data))

  transmit %({
    "event": "data",
    "channel": "/sites/site_id/stats/maps/map_id/clients",
    "data": #{client_data.to_json}
  })

  expect_http_request do |req, res|
    req.method.should eq("GET")
    req.path.should eq("/api/v1/sites/site_id/stats/clients/5684dae9ac8b")
    req.headers["Authorization"]?.should eq("Token token")
    respond_with 200, client_data
  end

  # wait for the 3 second sync to complete
  sleep 3.5

  status["63eda950-c6da-11e4-a628-60f81dd250cc"].should eq(JSON.parse("[#{client_data}]"))
end
