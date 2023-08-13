require "placeos-driver"
require "oauth2"
require "./releezme/*"

# documentation: https://acc-sapi.releezme.net/swagger/ui/index

class Vecos::Releezme < PlaceOS::Driver
  descriptive_name "Vecos Releezme Gateway"
  generic_name :ReleezmeLockers
  uri_base "https://acc-sapi.releezme.net"

  default_settings({
    client_id:                      "8537d5c8-a85c-4657-bc6b-7c35b1405464",
    client_secret:                  "856b5b85d3eb4697369",
    username:                       "admin",
    password:                       "admin",
    releezme_authentication_domain: "acc-identity.releezme.net",
  })

  def on_load
    on_update
  end

  def on_update
    client_id = setting(String, :client_id)
    client_secret = setting(String, :client_secret)
    username = setting(String, :username)
    password = setting(String, :password)
    releezme_authentication_domain = setting(String, :releezme_authentication_domain)

    transport.before_request do |req|
      access_token = get_access_token(client_id, client_secret, username, password, releezme_authentication_domain)
      req.headers["Authorization"] = access_token
      req.headers["Content-Type"] = "application/json"
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  @expires : Time = Time.utc
  @bearer_token : String = ""
  @access_token : OAuth2::AccessToken? = nil

  protected def get_access_token(client_id, client_secret, username, password, releezme_authentication_domain)
    return @bearer_token if 1.minute.from_now < @expires

    # check if we are running a spec
    if config.uri.as(String).includes?("127.0.0.1")
      uri = URI.parse config.uri.as(String)
      auth_domain = uri.host.as(String)
      port = uri.port.as(Int32)
      scheme = "http"
    else
      auth_domain = releezme_authentication_domain
      scheme = "https"
    end

    # use the built in crystal oauth client
    client = OAuth2::Client.new(auth_domain, client_id, client_secret, scheme: scheme, port: port, token_uri: "/connect/token")
    token = if (access_token = @access_token) && access_token.refresh_token.presence
              begin
                client.get_access_token_using_refresh_token(access_token.refresh_token)
              rescue error : OAuth2::Error
                logger.warn(exception: error) { "failed to refresh token" }
                client.get_access_token_using_resource_owner_credentials(username: username, password: password, scope: "Vecos.Releezme.Web.SAPI offline_access")
              end
            else
              client.get_access_token_using_resource_owner_credentials(username: username, password: password, scope: "Vecos.Releezme.Web.SAPI offline_access")
            end
    @expires = token.expires_in.as(Int64).seconds.from_now
    @access_token = token
    @bearer_token = "Bearer #{token.access_token}"
  end

  @[Security(Level::Support)]
  def fetch_pages(location : String) : Array(JSON::Any)
    append = location.includes?('?') ? '&' : '?'
    next_page = "#{location}#{append}pageNumber=#{1}"
    data = [] of JSON::Any

    loop do
      response = get(next_page)
      @expires = 1.minute.ago if response.status_code == 401
      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      payload = JSON.parse(response.body).as_h
      pages = if has_paging = payload.delete("Paging")
                Paging.from_json has_paging.to_json
              end
      data.concat payload[payload.keys.first].as_a

      break unless pages && pages.has_next_page

      next_page = "#{location}#{append}pageNumber=#{pages.page_number + 1}"
    end

    data
  end

  @[Security(Level::Support)]
  def fetch_item(location : String) : String
    response = get(location)
    @expires = 1.minute.ago if response.status_code == 401
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }
    response.body
  end

  @[Security(Level::Support)]
  def bearer_token
    @bearer_token
  end

  # ===============
  #  COMPANIES
  # ===============

  def companies
    JSON.parse(fetch_item("/api/companies"))["Companies"]
  end

  # =======================
  #  LOCATIONS / Buildings
  # =======================

  # typically these are buildings
  def locations
    fetch_pages("/api/locations?pageSize=200")
  end

  def location(location_id : String)
    Location.from_json fetch_item("/api/locations/#{location_id}")
  end

  # typically these are floors in the building
  def location_sections(location_id : String)
    fetch_pages("/api/locations/#{location_id}/sections?pageSize=200")
  end

  # ===================
  #  SECTIONS / Levels
  # ===================

  # all floors from all buildings in one request
  def sections
    fetch_pages("/api/sections?pageSize=200")
  end

  def section(section_id : String)
    Section.from_json fetch_item("/api/locations/#{section_id}")
  end

  def section_locker_banks(section_id : String)
    fetch_pages("/api/sections/#{section_id}/lockerbanks?pageSize=200")
  end

  # banks and groups in the banks that the user can allocate to themselves
  def section_banks_allocatable(section_id : String, user_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
      form.add "pageSize", "200"
    end
    fetch_pages("/api/sections/#{section_id}/lockerbanklockergroups/allocatable?#{params}")
  end

  # =====================================
  #  BANKS / lockers physically together
  # =====================================

  def banks
    fetch_pages("/api/lockerbanks?pageSize=200")
  end

  def bank(bank_id : String)
    LockerBank.from_json fetch_item("/api/lockerbanks/#{bank_id}")
  end

  def bank_groups(bank_id : String)
    fetch_pages("/api/lockerbanks/#{bank_id}/lockergroups?pageSize=200")
  end

  # returns all the lockers in the bank without paging (but paging json is included)
  def bank_lockers(bank_id : String)
    fetch_pages("/api/lockerbanks/#{bank_id}/lockers?pageSize=200")
  end

  def bank_group_lockers_available(bank_id : String, group_id : String)
    fetch_pages("/api/lockerbanks/#{bank_id}/#{group_id}/availablelockers?pageSize=200")
  end

  # NOTE:: Only accessible to System Control Clients
  def bank_locker_allocations(bank_id : String)
    fetch_pages("/api/lockerbanks/#{bank_id}/allocations?pageSize=200")
  end

  # ===============================================
  #  GROUPS / lockers assigned to a group of users
  # ===============================================

  def groups
    fetch_pages("/api/lockergroups?pageSize=200")
  end

  def group(group_id : String)
    Array(LockerGroup).from_json fetch_item("/api/lockergroups/#{group_id}")
  end

  def group_locker_banks(group_id : String)
    fetch_pages("/api/lockergroups/#{group_id}/lockerbanks?pageSize=200")
  end

  # =====================================
  #  BOOKINGS
  # =====================================

  def bookings(user_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
      form.add "pageSize", "200"
    end
    fetch_pages("/api/bookings?#{params}")
  end

  def bookings_availability(
    user_id : String,
    starting : Int64,
    ending : Int64,
    section_id : String? = nil,
    location_id : String? = nil,
    bank_id : String? = nil,
    group_id : String? = nil,
    locker_id : String? = nil
  )
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
      form.add "startDateTimeUtc", Time.unix(starting).to_rfc3339
      form.add "endDateTimeUtc", Time.unix(ending).to_rfc3339
      form.add "sectionId", section_id.as(String) if section_id.presence
      form.add "locationId", location_id.as(String) if location_id.presence
      form.add "lockerBankId", bank_id.as(String) if bank_id.presence
      form.add "lockerBankId", group_id.as(String) if bank_id.presence && group_id.presence
      form.add "lockerId", locker_id.as(String) if locker_id.presence
      form.add "pageSize", "200"
    end
    fetch_pages("/api/bookings/availability?#{params}")
  end

  def book_locker(starting : Int64, ending : Int64, user_id : String, locker_id : String? = nil, group_id : String? = nil, bank_id : String? = nil, timezone : String = "UTC")
    tz = Time::Location.load(timezone)
    response = post("/api/bookings", body: {
      # this seems like a stupid data format? I assume as the locker bank has the timezone?
      "StartDateTimeUtc" => Time.unix(starting).in(tz).to_s("%m-%d-%Y %H:%M:%S"),
      "EndDateTimeUtc"   => Time.unix(ending).in(tz).to_s("%m-%d-%Y %H:%M:%S"),
      "LockerGroupId"    => group_id,
      "LockerBankId"     => bank_id,
      "LockerId"         => locker_id,
      "ExternalUserId"   => user_id,
    }.to_json)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  # =====================================
  #  LOCKERS
  # =====================================

  # the lockers that are currently allocated to the specified user
  # the user ID is typically email - defined by the client
  def lockers_allocated_to(user_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
      form.add "pageSize", "200"
    end
    fetch_pages("/api/lockers/allocated?#{params}")
  end

  # check if a user can be allocated a new locker
  def can_allocate_locker?(user_id : String) : String
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
    end
    response = get("/api/lockers/canallocate?#{params}")
    response.body
  end

  def locker_allocate(locker_id : String, user_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id
    end
    response = post("/api/lockers/#{locker_id}/allocate?#{params}")
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def locker_allocate_random(bank_id : String, group_id : String, user_id : String)
    params = URI::Params.build do |form|
      form.add "lockerBankId", bank_id
      form.add "lockerGroupId", group_id
      form.add "externalUserId", user_id
    end
    response = post("/api/lockers/allocate?#{params}")
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def locker_release(locker_id : String, user_id : String? = nil) : Nil
    params = URI::Params.build do |form|
      form.add "externalUserId", user_id if user_id.presence
    end
    response = post("/api/lockers/#{locker_id}/release?#{params}")
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
  end

  def locker_unlock(locker_id : String, pin_code : String? = nil)
    pin_route = pin_code ? nil : "/withoutpincode"
    response = post("/api/lockers/#{locker_id}/pincode/unlock#{pin_route}", body: pin_code)
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
  end

  # =====================================
  #  SHARING
  # =====================================

  def share_locker_with(locker_id : String, owner_id : String, user_id : String) : Bool
    params = URI::Params.build do |form|
      form.add "externalUserId", owner_id
      form.add "sharedUserId", user_id
    end
    response = post("/api/lockers/#{locker_id}/share?#{params}")
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    true
  end

  def unshare_locker(locker_id : String, owner_id : String, shared_with_internal_id : String? = nil) : Bool
    params = URI::Params.build do |form|
      form.add "externalUserId", owner_id
    end
    response = post("/api/lockers/#{locker_id}/unshare/#{shared_with_internal_id}?#{params}")
    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    true
  end

  def can_share_locker_with?(locker_id : String, owner_id : String, search : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", owner_id
      form.add "searchString", search
    end
    Array(LockerUsers).from_json(fetch_item("/api/lockers/#{locker_id}/shareablelockerusers?#{params}"), root: "LockerUsers")
  end

  def locker_shared_with?(locker_id : String, owner_id : String)
    params = URI::Params.build do |form|
      form.add "externalUserId", owner_id
    end
    Array(LockerUsers).from_json(fetch_item("/api/lockers/#{locker_id}/shareablelockerusers?#{params}"), root: "LockerUsers")
  end
end
