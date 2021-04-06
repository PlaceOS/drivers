require "xml"

class Cisco::Ise::Guests < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco ISE Guest Control"
  generic_name :Guests
  uri_base "https://ise-pan:9060/ers/config"

  default_settings({
    # We may grab this data through discovery mechanisms in the future but for now use a setting
    auth_token:        "auth_token",
    sponsor_user_name: "sponsor",
    portal_id:         "portal101",
    timezone:          "Australia/Sydney",
  })

  @auth_token : String = ""
  @sponsor_user_name : String = ""
  @portal_id : String = ""
  @sms_service_provider : String? = nil
  @timezone : Time::Location = Time::Location.load("Australia/Sydney")

  # See https://www.cisco.com/c/en/us/td/docs/security/ise/1-4/api_ref_guide/api_ref_book/ise_api_ref_ers2.html#42003
  TYPE_HEADER = "application/vnd.com.cisco.ise.identity.guestuser.2.0+xml"
  TIME_FORMAT = "%m/%d/%Y %H:%M"

  def on_load
    on_update
  end

  def on_update
    @auth_token = setting?(String, :auth_token) || "auth_token"
    @sponsor_user_name = setting?(String, :sponsor_user_name) || "sponsor"
    @portal_id = setting?(String, :portal_id) || "portal101"
    @sms_service_provider = setting?(String, :sms_service_provider)

    time_zone = setting?(String, :timezone).presence
    @timezone = Time::Location.load(time_zone) if time_zone
  end

  def create_guest(
    event_start : Int64,
    attendee_email : String,
    attendee_name : String,
    company_name : String? = nil,
    phone_number : String? = nil,
    sms_service_provider : String? = nil,
    sponsor_user_name : String? = nil,
    portal_id : String? = nil
  )
    return guest_crendentials("test") if setting?(Bool, :test)
    sponsor_user_name ||= @sponsor_user_name
    portal_id ||= @portal_id
    sms_service_provider ||= @sms_service_provider

    time_object = Time.unix(event_start).in(@timezone)
    from_date = time_object.at_beginning_of_day.to_s(TIME_FORMAT)
    to_date = time_object.at_end_of_day.to_s(TIME_FORMAT)

    # Determine the name of the attendee for ISE
    guest_names = attendee_name.split
    first_name_index_end = guest_names.size > 1 ? -2 : -1
    first_name = guest_names[0..first_name_index_end].join(' ')
    last_name = guest_names[-1]

    # If company_name isn't passed
    # Hackily grab a company name from the attendee's email (we may be able to grab this from the signal if possible)
    company_name ||= attendee_email.split('@')[1].split('.')[0].capitalize

    # Now generate our XML body
    xml_string = %(
      <?xml version="1.0" encoding="UTF-8"?>
      <ns2:guestuser xmlns:ns2="identity.ers.ise.cisco.com">
        <guestAccessInfo>
          <fromDate>#{from_date}</fromDate>
          <toDate>#{to_date}</toDate>
          <validDays>1</validDays>
        </guestAccessInfo>
        <guestInfo>
          <company>#{company_name}</company>
          <emailAddress>#{attendee_email}</emailAddress>
          <firstName>#{first_name}</firstName>
          <lastName>#{last_name}</lastName>
          <notificationLanguage>English</notificationLanguage>
    )

    xml_string += %(
          <phoneNumber>#{phone_number}</phoneNumber>
          <smsServiceProvider>#{sms_service_provider}</smsServiceProvider>
    ) if phone_number && sms_service_provider

    xml_string += %(
          <userName>#{UUID.random}</userName>
        </guestInfo>
        <guestType>Daily</guestType>
        <personBeingVisited>#{sponsor_user_name}</personBeingVisited>
        <portalId>#{portal_id}</portalId>
        <reasonForVisit>interview</reasonForVisit>
      </ns2:guestuser>
    )

    response = post("/guestuser/", body: xml_string, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => "Basic #{@auth_token}",
    })

    raise "failed to create guest, code #{response.status_code}\n#{response.body}" unless response.success?

    guest_id = response.headers["Location"].split('/').last
    guest_crendentials(guest_id)
  end

  def guest_crendentials(id : String)
    return {username: UUID.random.to_s, password: UUID.random.to_s} if setting?(Bool, :test)
    response = get("/guestuser/#{id}", headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => "Basic #{@auth_token}",
    })
    parsed_body = XML.parse(response.body)
    guest_user = parsed_body.first_element_child.not_nil!
    guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
    {
      username: guest_info.children.find { |c| c.name == "userName" }.not_nil!.content,
      password: guest_info.children.find { |c| c.name == "password" }.not_nil!.content
    }
  end
end
