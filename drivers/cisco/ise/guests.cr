require "xml"

# Tested with Cisco ISE API v2.2
# https://developer.cisco.com/docs/identity-services-engine/3.0/#!guest-user/resource-definition
# However, should work and conform to v1.4 requirements
# https://www.cisco.com/c/en/us/td/docs/security/ise/1-4/api_ref_guide/api_ref_book/ise_api_ref_guest.html#79039

class Cisco::Ise::Guests < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco ISE Guest Control"
  generic_name :Guests
  uri_base "https://ise-pan:9060/ers/config"

  default_settings({
    username:   "user",
    password:   "pass",
    portal_id:  "Required, ask cisco ISE admins",
    timezone:   "Australia/Sydney",
    guest_type: "Required, ask cisco ISE admins for valid subset of values",                              # e.g. Contractor
    location:   "Required for ISE v2.2, ask cisco ISE admins for valid value. Else, remove for ISE v1.4", # e.g. New York
    custom_data: {} of String => JSON::Any::Type
  })

  @basic_auth : String = ""
  @portal_id : String = ""
  @sms_service_provider : String? = nil
  @guest_type : String = "default_guest_type"
  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @location : String? = nil
  @custom_data = {} of String => JSON::Any::Type

  TYPE_HEADER = "application/vnd.com.cisco.ise.identity.guestuser.2.0+xml"
  TIME_FORMAT = "%m/%d/%Y %H:%M"

  def on_load
    on_update
  end

  def on_update
    @basic_auth = "Basic #{Base64.strict_encode("#{setting?(String, :username)}:#{setting?(String, :password)}")}"
    @portal_id = setting?(String, :portal_id) || "portal101"
    @guest_type = setting?(String, :guest_type) || "default_guest_type"
    @location = setting?(String, :location)
    @sms_service_provider = setting?(String, :sms_service_provider)

    time_zone = setting?(String, :timezone).presence
    @timezone = Time::Location.load(time_zone) if time_zone
    @custom_data = setting?(Hash(String, JSON::Any::Type), :custom_data) || {} of String => JSON::Any::Type
  end

  def create_guest(
    event_start : Int64,
    attendee_email : String,
    attendee_name : String,
    company_name : String? = nil,         # Mandatory but driver will extract from email if not passed
    phone_number : String = "0123456789", # Mandatory, use a fake value as default
    sms_service_provider : String? = nil, # Use this param to override the setting
    guest_type : String? = nil,           # Mandatory but use this param to override the setting
    portal_id : String? = nil             # Mandatory but use this param to override the setting
  )
    # Determine the name of the attendee for ISE
    guest_names = attendee_name.split
    first_name_index_end = guest_names.size > 1 ? -2 : -1
    first_name = guest_names[0..first_name_index_end].join(' ')
    last_name = guest_names[-1]

    return {"username" => "#{first_name[0].downcase}#{last_name.underscore}", "password" => UUID.random.to_s[0..3]}.merge(@custom_data) if setting?(Bool, :test)

    sms_service_provider ||= @sms_service_provider
    guest_type ||= @guest_type
    portal_id ||= @portal_id

    time_object = Time.unix(event_start).in(@timezone)
    from_date = time_object.at_beginning_of_day.to_s(TIME_FORMAT)
    to_date = time_object.at_end_of_day.to_s(TIME_FORMAT)

    # If company_name isn't passed
    # Hackily grab a company name from the attendee's email (we may be able to grab this from the signal if possible)
    company_name ||= attendee_email.split('@')[1].split('.')[0].capitalize

    # Now generate our XML body
    xml_string = %(<?xml version="1.0" encoding="UTF-8"?>
      <ns2:guestuser xmlns:ns2="identity.ers.ise.cisco.com">)

    # customFields is required for ISE API v2.2
    # since location is also required for 2.2, we can check if location is present
    xml_string += %(
        <customFields></customFields>) if @location

    xml_string += %(
        <guestAccessInfo>
          <fromDate>#{from_date}</fromDate>)

    xml_string += %(
          <location>#{@location}</location>) if @location

    xml_string += %(
          <toDate>#{to_date}</toDate>
          <validDays>1</validDays>
        </guestAccessInfo>
        <guestInfo>
          <company>#{company_name}</company>
          <emailAddress>#{attendee_email}</emailAddress>
          <firstName>#{first_name}</firstName>
          <lastName>#{last_name}</lastName>
          <notificationLanguage>English</notificationLanguage>
          <phoneNumber>#{phone_number}</phoneNumber>)

    xml_string += %(
          <smsServiceProvider>#{sms_service_provider}</smsServiceProvider>) if sms_service_provider

    xml_string += %(
        </guestInfo>
        <guestType>#{guest_type}</guestType>
        <portalId>#{portal_id}</portalId>
      </ns2:guestuser>)

    response = post("/guestuser/", body: xml_string, headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })

    raise "failed to create guest, code #{response.status_code}\n#{response.body}" unless response.success?

    guest_id = response.headers["Location"].split('/').last
    guest_crendentials(guest_id).merge(@custom_data)
  end

  def guest_crendentials(id : String)
    response = get("/guestuser/#{id}", headers: {
      "Accept"        => TYPE_HEADER,
      "Content-Type"  => TYPE_HEADER,
      "Authorization" => @basic_auth,
    })
    parsed_body = XML.parse(response.body)
    guest_user = parsed_body.first_element_child.not_nil!
    guest_info = guest_user.children.find { |c| c.name == "guestInfo" }.not_nil!
    {
      "username" => guest_info.children.find { |c| c.name == "userName" }.not_nil!.content,
      "password" => guest_info.children.find { |c| c.name == "password" }.not_nil!.content
    }
  end
end
