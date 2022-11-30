require "placeos-driver"
require "ise"

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
    username:    "user",
    password:    "pass",
    portal_id:   "Required, ask cisco ISE admins",
    timezone:    "Australia/Sydney",
    guest_type:  "Required, ask cisco ISE admins for valid subset of values",                              # e.g. Contractor
    location:    "Required for ISE v2.2, ask cisco ISE admins for valid value. Else, remove for ISE v1.4", # e.g. New York
    custom_data: {} of String => String,
    debug:       false,
  })

  protected getter! client : ISE::Client

  @guest_type : String = "default_guest_type"
  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @location : String? = nil
  @custom_data = {} of String => String

  TYPE_HEADER = "application/json"
  TIME_FORMAT = "%m/%d/%Y %H:%M"

  def on_load
    on_update
  end

  def on_update
    username = setting(String, :username)
    password = setting(String, :password)

    session = ISE::Session.new(base_url: config.uri.not_nil!.to_s, username: username, password: password)
    @client = ISE::Client.new(session: session)

    @debug = setting?(Bool, :debug) || false
    @guest_type = setting?(String, :guest_type) || "default_guest_type"

    @location = setting?(String, :location)

    time_zone = setting?(String, :timezone).presence
    @timezone = Time::Location.load(time_zone) if time_zone
    @custom_data = setting?(Hash(String, String), :custom_data) || {} of String => String
  end

  def create_internal(
    event_start : Int64,
    attendee_email : String,
    attendee_name : String,
    company_name : String? = nil,         # Mandatory but driver will extract from email if not passed
    phone_number : String = "0123456789", # Mandatory, use a fake value as default
    guest_type : String? = nil            # Mandatory but use this param to override the setting
  )
    # Determine the name of the attendee for ISE
    guest_names = attendee_name.split
    first_name_index_end = guest_names.size > 1 ? -2 : -1
    first_name = guest_names[0..first_name_index_end].join(' ')
    last_name = guest_names[-1]

    username = genererate_username(first_name, last_name)
    password = genererate_password(first_name, last_name)

    return {"username" => username, "password" => UUID.random.to_s[0..3]}.merge(@custom_data) if setting?(Bool, :test)

    guest_type ||= @guest_type

    time_object = Time.unix(event_start).in(@timezone)
    from_date = time_object.at_beginning_of_day.to_s(TIME_FORMAT)
    to_date = time_object.at_end_of_day.to_s(TIME_FORMAT)

    # If company_name isn't passed
    # Hackily grab a company name from the attendee's email (we may be able to grab this from the signal if possible)
    company_name ||= attendee_email.split('@')[1].split('.')[0].capitalize

    # These attributes must be pre-defined in the ISE admin panel before
    # we actually start creating internal users since it will raise an error
    # of unknown attributes being passed into the API.
    attributes = {
      "fromDate"    => from_date,
      "toDate"      => to_date,
      "location"    => @location.to_s,
      "companyName" => company_name,
      "phoneNumber" => phone_number,
      "guestType"   => guest_type,
    } of String => String

    attributes.merge!(@custom_data)

    internal_user = @client.not_nil!.internal_user.create(name: username, password: password, first_name: first_name, last_name: last_name, email: attendee_email, attributes: attributes)

    logger.debug { "Internal User: #{internal_user.to_json}" } if @debug

    internal_user
  end

  def get_internal_user_by_id(id : String)
    @client.not_nil!.internal_user.get(id)
  end

  def get_internal_user_by_name(name : String)
    @client.not_nil!.internal_user.get_by_name(name)
  end

  # Will be 9 characters in length until 2081-08-05 10:16:46.208000000 UTC
  # when it will increase to 10
  private def genererate_username(firstname, lastname)
    "#{firstname[0].downcase}#{lastname[0].downcase}#{Time.utc.to_unix_ms.to_s(62)}"
  end

  # Will be 9 characters in length until 2081-08-05 10:16:46.208000000 UTC
  # when it will increase to 10
  private def genererate_password(firstname, lastname)
    "P!#{lastname[0].downcase}#{firstname[0].downcase}#{Time.utc.to_unix_ms.to_s(31)}"
  end
end
