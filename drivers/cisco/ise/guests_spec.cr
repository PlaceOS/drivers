require "xml"
require "placeos-driver"
require "./guests"

DriverSpecs.mock_driver "Cisco::Ise::Guests" do
  start_time = Time.local(Time::Location.load("Australia/Sydney"))
  start_date = start_time.at_beginning_of_day.to_s(Cisco::Ise::Guests::TIME_FORMAT)
  end_date = start_time.at_end_of_day.to_s(Cisco::Ise::Guests::TIME_FORMAT)
  attendee_email = "attendee@test.com"
  company_name = "PlaceOS"
  first = "First Middle"
  last = "Last"
  name = "#{first} #{last}"
  user = nil
  sponsor = "sponsor"

  resp = exec(:create_guest, start_time.to_unix, attendee_email, name, company_name)

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
    to_date = guest_access_info.children.find { |c| c.name == "toDate" }.not_nil!.content
    to_date.should eq end_date

    guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
    company = guest_info.children.find { |c| c.name == "company" }.not_nil!.content
    company.should eq company_name
    email_address = guest_info.children.find { |c| c.name == "emailAddress" }.not_nil!.content
    email_address.should eq attendee_email
    first_name = guest_info.children.find { |c| c.name == "firstName" }.not_nil!.content
    first_name.should eq first
    last_name = guest_info.children.find { |c| c.name == "lastName" }.not_nil!.content
    last_name.should eq last
    phone_number = guest_info.children.find { |c| c.name == "phoneNumber" }
    phone_number.should eq nil
    sms_service_provider = guest_info.children.find { |c| c.name == "smsServiceProvider" }
    sms_service_provider.should eq nil
    user_name = guest_info.children.find { |c| c.name == "userName" }.not_nil!.content
    user = user_name
    pp "userName = #{user_name}"

    person_being_visited = guest_user.children.find { |c| c.name == "personBeingVisited" }.not_nil!.content
    person_being_visited.should eq sponsor
    portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
    portal_id.should eq "portal101"

    response.status_code = 201
    response.headers["Location"] = location
    response.headers["Content-Type"] = "application/xml"
  end

  pass = "12345"
  # GET to /guestuser/
  expect_http_request do |_, response|
    response.status_code = 200
    response.headers["Content-Type"] = "application/xml"
    response << %(
      <?xml version="1.0" encoding="UTF-8"?>
      <ns3:guestuser xmlns:ns2="ers.ise.cisco.com" xmlns:ns3="identity.ers.ise.cisco.com" name="user1" id="b4bdf2b0-73e1-11e3-8cdf-000c29c56fc6">
        <link type="application/xml" href="#{location}" rel="self"/>
        <customFields/>
        <guestAccessInfo>
          <fromDate>#{start_date}</fromDate>
          <toDate>#{end_date}</toDate>
          <validDays>1</validDays>
        </guestAccessInfo>
        <guestInfo>
        <company>Cisco</company>
        <creationTime>#{start_time.to_s(Cisco::Ise::Guests::TIME_FORMAT)}</creationTime>
        <emailAddress>#{attendee_email}</emailAddress>
        <enabled>true</enabled>
        <firstName>#{first}</firstName>
        <lastName>#{last}</lastName>
        <notificationLanguage>English</notificationLanguage>
        <password>#{pass}</password>
        <userName>#{user}</userName>
        </guestInfo>
        <guestType>Daily (default)</guestType>
        <personBeingVisited>#{sponsor}</personBeingVisited>
        <reasonForVisit>Interview</reasonForVisit>
        <sponsorUserName>SponsoredUser1</sponsorUserName>
        <status>Awaiting Initial Login</status>
      </ns3:guestuser>
    )
  end

  credentials = resp.get.not_nil!
  credentials["username"].should eq(user)
  credentials["password"].should eq(pass)

  phone = "0123456789"
  sms = "Global Default"
  exec(:create_guest, start_time.to_unix, attendee_email, "First Last", nil, phone, sms)

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
    company.should eq "Test"
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
    user_name = guest_info.children.find { |c| c.name == "userName" }.not_nil!.content
    pp "userName = #{user_name}"

    person_being_visited = guest_user.children.find { |c| c.name == "personBeingVisited" }.not_nil!.content
    person_being_visited.should eq "sponsor"
    portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
    portal_id.should eq "portal101"

    response.status_code = 201
    response.headers["Location"] = "https://ise-pan:9060/ers/config/guestuser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc7"
    response.headers["Content-Type"] = "application/xml"
  end
end
