require "placeos-driver"
require "twenty-five-live-pro"

class TwentyFiveLive::Pro::API < PlaceOS::Driver
  descriptive_name "25 Live Pro API Gateway"
  generic_name :Bookings
  uri_base "https://example.com/r25ws/wrd/partners/run/external"

  alias Client = TwentyFiveLivePro::Client

  default_settings({username: "admin", password: "admin"})

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    base_url = config.uri.not_nil!.to_s

    username = setting(String, :username)
    password = setting(String, :password)

    @client = TwentyFiveLivePro::Client.new(base_url: base_url, username: username, password: password)
  end

  def get_space_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
    @client.not_nil!.spaces.get(id, included_elements, expanded_elements)
  end

  def list_spaces(page : Int32 = 0, items_per_age : Int32 = 10, since : String? = nil, paginate : String? = nil)
    @client.not_nil!.spaces.list(page, items_per_age, since, paginate)
  end

  def availability(id : Int32, start_date : String, end_date : String, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
    @client.not_nil!.spaces.availability(id, start_date, end_date, included_elements, expanded_elements)
  end

  def get_resource_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
    @client.not_nil!.resources.get(id, included_elements, expanded_elements)
  end

  def list_resources(page : Int32 = 0, items_per_age : Int32 = 10, since : String? = nil, paginate : String? = nil)
    @client.not_nil!.resources.list(page, items_per_age, since, paginate)
  end

  def get_organization_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
    @client.not_nil!.organizations.get(id, included_elements, expanded_elements)
  end

  def list_organizations(page : Int32 = 0, items_per_age : Int32 = 10, since : String? = nil, paginate : String? = nil)
    @client.not_nil!.organizations.list(page, items_per_age, since, paginate)
  end

  def get_event_details(id : Int32, included_elements : Array(String) = [] of String, expanded_elements : Array(String) = [] of String)
    @client.not_nil!.events.get(id, included_elements, expanded_elements)
  end

  def list_events(page : Int32 = 0, items_per_age : Int32 = 10, since : String? = nil, paginate : String? = nil)
    @client.not_nil!.events.list(page, items_per_age, since, paginate)
  end
end
