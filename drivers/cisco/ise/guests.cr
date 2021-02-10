module Cisco; end

module Cisco::Ise; end

module Cisco::Ise::Guests < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco ISE Guest Control"
  generic_name :Guests

  default_settings({
     # We may grab this data through discovery mechanisms in the future but for now use a setting
    endpoint: "https://ise-pan:9060/ers/config"
    auth_token: nil
  })

  def on_load
    # Guest has arrived in the lobby
    monitor("staff/guest/checkin") { |_subscription, payload| guest_checkin(payload)) }

    on_update
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

  def guest_checkin
    logger.debug { "received guest event payload: #{payload}" }
    guest_details = GuestEvent.from_json payload

    # TODO: Ensure that this is getting the correct day due to timezone
    # Also note that this uses American time formatting
    from_date = Time.at(guest_details.event_starting).at_beginning_of_day.to_s("%m/%d/%Y %H:%M")
    to_date = Time.at(guest_details.event_starting).at_end_of_day.to_s("%m/%d/%Y %H:%M")

    # Determine the name of the attendee for ISE
    guest_names = guest_details.attendee_name.split(" ")
    if guest_names.length > 1
      # If the attendee has at least two names, split them out and use all but the last as 'first name'
      first_name = guest_names[0..-2]
      last_name = guest_names[-1]
    else
      # Otherwise just use the one name (if no name was input when creating the event this could be an email)
      first_name = guest_details.attendee_name
      last_name = first_name
    end

    xml_string = %(
    <?xml version="1.0" encoding="UTF-8"?>
    <ns2:guestuser
        xmlns:ns2="identity.ers.ise.cisco.com">
        <guestAccessInfo>
            <fromDate>#{from_date}</fromDate>
            <toDate>#{to_date}</toDate>
            <validDays>1</validDays>
        </guestAccessInfo>
        <guestInfo>
            <company>New Company</company>
            <emailAddress>#{guest_details.attendee_email}</emailAddress>
            <firstName>#{first_name}</firstName>
            <lastName>#{last_name}</lastName>
            <notificationLanguage>English</notificationLanguage>
            <phoneNumber>9999998877</phoneNumber>
            <smsServiceProvider>Global Default</smsServiceProvider>
            <userName>autoguestuser1</userName>
        </guestInfo>
        <guestType>Daily</guestType>
        <personBeingVisited>sponsor</personBeingVisited>
        <portalId>portal101</portalId>
        <reasonForVisit>interview</reasonForVisit>
    </ns2:guestuser>)


    # We need to POST to the Cisco ISE guest endpoint
    # POST https://<ISE-Admin-Node>:9060/ers/config/guestuser/
    response = post("#{setting?(String, :endpoint)}/guestuser/", headers: {
        "Authorization" => "Basic #{setting?(String, :auth_token)}" 
      }, body: xml_string)
  end



end
