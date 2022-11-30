require "placeos-driver"
require "./guests"
require "placeos-driver/spec"
require "ise"

DriverSpecs.mock_driver "Cisco::Ise::Guests" do
  portal = "portal101"
  phone = "0123456789"
  type = "Contractor"
  lo = "New York"

  settings({
    portal_id:  portal,
    guest_type: type,
    location:   lo,
  })

  start_time = Time.local(Time::Location.load("Australia/Sydney"))
  start_date = start_time.at_beginning_of_day.to_s(Cisco::Ise::Guests::TIME_FORMAT)
  end_date = start_time.at_end_of_day.to_s(Cisco::Ise::Guests::TIME_FORMAT)
  attendee_email = "attendee@test.com"
  company_name = "PlaceOS"

  sms = "Global Default"
  exec(:create_internal, start_time.to_unix, attendee_email, "First Last", company_name, phone, sms, "Daily")

  # POST to /guestuser/
  expect_http_request do |request, response|
    parsed_body = JSON.parse(request.body.not_nil!)
    internal_user = ISE::Models::Internal::User.from_json(parsed_body["InternalUser"].to_json)

    internal_user.first_name = "First"
    internal_user.last_name = "Last"

    internal_user.email = attendee_email

    response.status_code = 201
    response.headers["Location"] = "https://ise-pan:9060/ers/config/guestuser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc7"
    response.headers["Content-Type"] = "application/json"
  end
end
