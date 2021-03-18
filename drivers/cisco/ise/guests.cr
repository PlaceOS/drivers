class Cisco::Ise::Guests < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco ISE Guest Control"
  generic_name :Guests
  uri_base "https://ise-pan:9060/ers/config"

  default_settings({
    # We may grab this data through discovery mechanisms in the future but for now use a setting
    auth_token: "auth_token",
    sponsor_user_name: "sponsor",
    portal_id: "portal101",
    sms_service_provider: "Global Default"
  })

  @auth_token : String = ""
  @sponsor_user_name : String = ""
  @portal_id : String = ""
  @sms_service_provider : String = ""

  def on_load
    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_checkin(payload) }

    on_update
  end

  def on_update
    @auth_token = setting?(String, :auth_token) || "auth_token"
    @sponsor_user_name = setting?(String, :sponsor_user_name) || "sponsor"
    @portal_id = setting?(String, :portal_id) || "portal101"
    @sms_service_provider = setting?(String, :sms_service_provider) || "Global Default"
  end

  class GuestEvent
    include JSON::Serializable

    property action : String
    property checkin : Bool?
    property system_id : String
    property event_id : String
    property host : String
    property resource : String
    property event_summary : String
    property event_starting : Int64
    property attendee_name : String
    property attendee_email : String
    property ext_data : Hash(String, JSON::Any)?
  end

  def guest_checkin(payload : String)
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = GuestEvent.from_json payload

    # TODO: Ensure that this is getting the correct day due to timezone
    # Use the server's local timezone for now
    # but if needed we can pass in a timezone using to_local_in
    # e.g. Time.unix(epoch).to_local_in(Time::Location.load("America/New_York"))
    # Also note that this uses American time formatting
    from_date = Time.unix(guest_details.event_starting).to_local.at_beginning_of_day.to_s("%m/%d/%Y %H:%M")
    to_date = Time.unix(guest_details.event_starting).to_local.at_end_of_day.to_s("%m/%d/%Y %H:%M")

    # Determine the name of the attendee for ISE
    guest_names = guest_details.attendee_name.split(" ")
    first_name = guest_names[0..-2].join
    last_name = guest_names[-1]

    # Hackily grab a company name from the attendee's email (we may be able to grab this from the signal if possible)
    # We can probably use some email library to do this more neatly
    company_name = guest_details.attendee_email.split("@")[1].split(".")[0].capitalize

    # Generate some generic username for this
    username = "autoguestuser#{Random.rand(100..999)}"

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
          <emailAddress>#{guest_details.attendee_email}</emailAddress>
          <firstName>#{first_name}</firstName>
          <lastName>#{last_name}</lastName>
          <notificationLanguage>English</notificationLanguage>
          <phoneNumber>9999998877</phoneNumber>
          <smsServiceProvider>#{@sms_service_provider}</smsServiceProvider>
          <userName>#{username}</userName>
        </guestInfo>
        <guestType>Daily</guestType>
        <personBeingVisited>#{@sponsor_user_name}</personBeingVisited>
        <portalId>#{@portal_id}</portalId>
        <reasonForVisit>interview</reasonForVisit>
      </ns2:guestuser>
    )

    response = post("/guestuser/", body: xml_string, headers: {
      "Authorization" => "Basic #{@auth_token}"
    })
  end
end
