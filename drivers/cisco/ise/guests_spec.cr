require "xml"

DriverSpecs.mock_driver "Cisco::Ise::Guests" do
  # Create a fake guest user payload for our spec
  payload = {
    action: :checkin,
    checkin: true,
    system_id: "system-id",
    event_id: "event-id",
    host: "host@email.com",
    resource: "resource",
    event_summary: "summary",
    event_starting: Time.local.to_unix,
    attendee_name: "Tester Attendee",
    attendee_email: "attendee@test.com",
    ext_data: {"ext_data": "Some JSON"}
  }.to_json

  # Call the function we 
  exec(:guest_checking, payload)

  # Now we can expext a POST to ISE creating that guest user based on the above details
  expect_http_request do |request, response|
    if request.method == "POST" && request.path == "/guestuser"
      # This is our interepted POST so parse the XML body
      parsed_body =  XML.parse(request.body)

      # Check through the parsed body to ensure POST is correct
    end
  end
end
