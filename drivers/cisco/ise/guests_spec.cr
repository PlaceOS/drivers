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

  exec(:guest_checkin, payload)

  # Now we can expext a POST to ISE creating that guest user based on the above details
  expect_http_request do |request, response|
    if (data = request.body.try(&.gets_to_end)) && request.method == "POST" && request.path == "/guestuser/"
      # This is our interepted POST so parse the XML body
      parsed_body = XML.parse(data)
      guest_user = parsed_body.first_element_child.not_nil!

      guest_access_info = guest_user.children.find { |c| c.name == "guestAccessInfo" }.not_nil!
      from_date = guest_access_info.children.find { |c| c.name == "fromDate" }.not_nil!.content
      to_date = guest_access_info.children.find { |c| c.name == "toDate" }.not_nil!.content

      guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
      company = guest_info.children.find { |c| c.name == "company" }.not_nil!.content
      email_address = guest_info.children.find { |c| c.name == "emailAddress" }.not_nil!.content
      first_name = guest_info.children.find { |c| c.name == "firstName" }.not_nil!.content
      last_name = guest_info.children.find { |c| c.name == "lastName" }.not_nil!.content
      sms_service_provider = guest_info.children.find { |c| c.name == "smsServiceProvider" }.not_nil!.content
      user_name = guest_info.children.find { |c| c.name == "userName" }.not_nil!.content

      person_being_visited = guest_user.children.find { |c| c.name == "personBeingVisited" }.not_nil!.content
      portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
    end
  end
end
