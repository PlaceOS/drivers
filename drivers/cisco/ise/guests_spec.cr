require "xml"
require "placeos-driver"
require "./guests"
require "./models/guest_user"
require "placeos-driver/spec"

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
  exec(:create_guest, start_time.to_unix, attendee_email, "First Last", company_name, phone, sms, "Daily")

  # POST to /guestuser/
  expect_http_request do |request, response|
    guest_user = Cisco::Ise::Models::GuestUser.from_json(request.body.not_nil!)

    guest_access_info = guest_user.guest_access_info

    from_date = guest_access_info.from_date
    from_date.should eq start_date

    to_date = guest_access_info.to_date
    to_date.should eq end_date

    guest_info = guest_user.guest_info

    company = guest_info.company
    company.should eq company_name

    email_address = guest_info.email_address
    email_address.should eq attendee_email

    first_name = guest_info.first_name
    first_name.should eq "First"

    last_name = guest_info.last_name
    last_name.should eq "Last"

    phone_number = guest_info.phone_number
    phone_number.should eq phone

    sms_service_provider = guest_info.sms_service_provider
    sms_service_provider.should eq sms

    portal_id = guest_user.portal_id
    portal_id.should eq portal

    guest_type = guest_user.guest_type
    guest_type.should eq "Daily"

    response.status_code = 201
    response.headers["Location"] = "https://ise-pan:9060/ers/config/guestuser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc7"
    response.headers["Content-Type"] = "application/xml"
  end
end
