require "xml"
require "placeos-driver"
require "./guests"

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
  first = "First Middle"
  last = "Last"
  name = "#{first} #{last}"

  exec(:create_guest, start_time.to_unix, attendee_email, name)

  guest_id = "e1bb8290-6ccb-11e3-8cdf-000c29c56fc6"
  location = "https://ise-pan:9060/ers/config/guestuser/#{guest_id}"
  # POST to /guestuser/
  expect_http_request do |request, response|
    # This is our interepted POST so parse the XML body
    parsed_body = XML.parse(request.body.not_nil!)
    guest_user = parsed_body.first_element_child.not_nil!

    guest_access_info = guest_user.children.find { |c| c.name == "guestAccessInfo" }.not_nil!
    from_date = guest_access_info.children.find { |c| c.name == "fromDate" }.not_nil!.content
    from_date.should eq start_date
    location = guest_access_info.children.find { |c| c.name == "location" }.not_nil!.content
    location.should eq lo
    to_date = guest_access_info.children.find { |c| c.name == "toDate" }.not_nil!.content
    to_date.should eq end_date

    guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
    company = guest_info.children.find { |c| c.name == "company" }.not_nil!.content
    company.should eq "Test"
    email_address = guest_info.children.find { |c| c.name == "emailAddress" }.not_nil!.content
    email_address.should eq attendee_email
    first_name = guest_info.children.find { |c| c.name == "firstName" }.not_nil!.content
    first_name.should eq first
    last_name = guest_info.children.find { |c| c.name == "lastName" }.not_nil!.content
    last_name.should eq last
    phone_number = guest_info.children.find { |c| c.name == "phoneNumber" }.not_nil!.content
    phone_number.should eq phone
    sms_service_provider = guest_info.children.find { |c| c.name == "smsServiceProvider" }
    sms_service_provider.should eq nil

    guest_type = guest_user.children.find { |c| c.name == "guestType" }.not_nil!.content
    guest_type.should eq type

    portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
    portal_id.should eq portal

    response.status_code = 201
    response.headers["Location"] = location
    response.headers["Content-Type"] = "application/xml"
  end

  sms = "Global Default"
  exec(:create_guest, start_time.to_unix, attendee_email, "First Last", company_name, phone, sms, "Daily")

  # POST to /guestuser/
  expect_http_request do |request, response|
    parsed_body = XML.parse(request.body.not_nil!)
    guest_user = parsed_body.first_element_child.not_nil!

    guest_access_info = guest_user.children.find { |c| c.name == "guestAccessInfo" }.not_nil!
    from_date = guest_access_info.children.find { |c| c.name == "fromDate" }.not_nil!.content
    from_date.should eq start_date
    to_date = guest_access_info.children.find { |c| c.name == "toDate" }.not_nil!.content
    to_date.should eq end_date

    guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
    company = guest_info.children.find { |c| c.name == "company" }.not_nil!.content
    company.should eq company_name
    email_address = guest_info.children.find { |c| c.name == "emailAddress" }.not_nil!.content
    email_address.should eq attendee_email
    first_name = guest_info.children.find { |c| c.name == "firstName" }.not_nil!.content
    first_name.should eq "First"
    last_name = guest_info.children.find { |c| c.name == "lastName" }.not_nil!.content
    last_name.should eq "Last"
    phone_number = guest_info.children.find { |c| c.name == "phoneNumber" }.not_nil!.content
    phone_number.should eq phone
    sms_service_provider = guest_info.children.find { |c| c.name == "smsServiceProvider" }.not_nil!.content
    sms_service_provider.should eq sms

    portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
    portal_id.should eq portal

    guest_type = guest_user.children.find { |c| c.name == "guestType" }.not_nil!.content
    guest_type.should eq "Daily"

    response.status_code = 201
    response.headers["Location"] = "https://ise-pan:9060/ers/config/guestuser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc7"
    response.headers["Content-Type"] = "application/xml"
  end
end
