require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::DNASpaces" do
  settings({
    dna_spaces_activation_key: "provide this and the API / tenant ids will be generated automatically",
    dna_spaces_api_key:        "X-API-KEY",
    tenant_id:                 "sfdsfsdgg",
    verify_activation_key:     false,
    max_location_age:          300,
    floorplan_mappings:        {
      location_a4cb0: {
        "level_name" => "optional name",
        "building"   => "zone-GAsXV0nc",
        "level"      => "zone-GAsmleH",
        "offset_x"   => 12.4,
        "offset_y"   => 5.2,
        "map_width"  => 50.3,
        "map_height" => 100.9,
      },
    },
    debug_stream: false,
  })

  # The dashboard should request the streaming API
  expect_http_request do |request, response|
    headers = request.headers
    if headers["X-API-KEY"]? == "X-API-KEY"
      response.headers["Transfer-Encoding"] = "chunked"
      response.status_code = 200
      response << %({"recordUid":"event-85b84f15","recordTimestamp":1605502585236,"spacesTenantId":"","spacesTenantName":"","partnerTenantId":"","eventType":"KEEP_ALIVE"})
    else
      response.status_code = 401
    end
  end

  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)
end
