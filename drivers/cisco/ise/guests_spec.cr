require "xml"

DriverSpecs.mock_driver "Cisco::Ise::Guests" do
  # Create a fake guest user payload for our spec
  start_time = Time.local
  start_date = start_time.to_local.at_beginning_of_day.to_s("%m/%d/%Y %H:%M")
  end_date = start_time.to_local.at_end_of_day.to_s("%m/%d/%Y %H:%M")
  attendee_email = "attendee@test.com"
  company_name = "PlaceOS"

  exec(:create_guest, start_time.to_unix, attendee_email, "First Middle Last", company_name)

  # Now we can expext a POST to ISE creating that guest user based on the above details
  expect_http_request do |request, response|
    if request.method == "POST" && request.path == "/guestuser/"
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
      company.should eq "PlaceOS"
      email_address = guest_info.children.find { |c| c.name == "emailAddress" }.not_nil!.content
      email_address.should eq attendee_email
      first_name = guest_info.children.find { |c| c.name == "firstName" }.not_nil!.content
      first_name.should eq "First Middle"
      last_name = guest_info.children.find { |c| c.name == "lastName" }.not_nil!.content
      last_name.should eq "Last"
      phone_number = guest_info.children.find { |c| c.name == "phoneNumber" }
      phone_number.should eq nil
      sms_service_provider = guest_info.children.find { |c| c.name == "smsServiceProvider" }
      sms_service_provider.should eq nil
      user_name = guest_info.children.find { |c| c.name == "userName" }.not_nil!.content
      pp "userName = #{user_name}"

      person_being_visited = guest_user.children.find { |c| c.name == "personBeingVisited" }.not_nil!.content
      person_being_visited.should eq "sponsor"
      portal_id = guest_user.children.find { |c| c.name == "portalId" }.not_nil!.content
      portal_id.should eq "portal101"

      response.status_code = 201
      response.headers["Location"] = "https://ise-pan:9060/ers/config/guestuser/e1bb8290-6ccb-11e3-8cdf-000c29c56fc6"
      response.headers["Content-Type"] = "application/xml"
    end

    phone = "0123456789"
    sms = "Global Default"
    exec(:create_guest, start_time.to_unix, attendee_email, "First Last", nil, phone, sms)

    expect_http_request do |request, response|
      if request.method == "POST" && request.path == "/guestuser/"
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
  end
end
