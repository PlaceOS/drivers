require "placeos-driver"
require "./network_access"
require "./models/internal_user"
require "placeos-driver/spec"

DriverSpecs.mock_driver "Cisco::Ise::NetworkAccess" do
  # Mock data for GUEST Users only
  # portal = "portal101"
  # phone = "0123456789"
  # type = "Contractor"
  # lo = "New York"
  # settings({
  #   portal_id:  portal,
  #   guest_type: type,
  #   location:   lo,
  # })
  # start_time = Time.local(Time::Location.load("Australia/Sydney"))
  # start_date = start_time.at_beginning_of_day.to_s(Cisco::Ise::NetworkAccess::TIME_FORMAT)
  # end_date = start_time.at_end_of_day.to_s(Cisco::Ise::NetworkAccess::TIME_FORMAT)
  

  # Test INTERNAL User creation
  attendee_email = "attendee@test.com"
  exec(:create_internal, email: attendee_email, name: attendee_email)   # The attendee name must be unique, and in most real-world use cases, the clients prefer that to be the email address
  # POST to /internaluser/
  expect_http_request do |request, response|
    parsed_body = JSON.parse(request.body.not_nil!)
    internal_user = Cisco::Ise::Models::InternalUser.from_json(parsed_body["InternalUser"].to_json)

    email_address = internal_user.email
    email_address.should eq attendee_email

    name = internal_user.name
    name.should eq attendee_email

    response.status_code = 201
    response.headers["Location"] = "https://ise-pan:9060/ers/config/internaluser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc7"
    response.headers["Content-Type"] = "application/xml"
  end
end
