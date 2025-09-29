require "placeos-driver"
require "placeos-driver/interface/door_security"
require "placeos-driver/interface/zone_access_security"
require "uri"
require "semantic_version"
require "./rest_api_models"
require "base64"

# Documentation: https://aca.im/driver_docs/Gallagher/Gallagher_CC_REST_API_Docs%208.10.1113.zip
# https://gallaghersecurity.github.io/

class Gallagher::RestAPI < PlaceOS::Driver
  include Interface::DoorSecurity
  include Interface::ZoneAccessSecurity

  # Discovery Information:
  generic_name :Gallagher
  descriptive_name "Gallagher Security System"
  uri_base "https://gallagher.your.org"

  default_settings({
    api_key:         "your api key",
    unique_pdf_name: "email",

    # The division to pass when creating cardholders.
    default_division_href: "",

    # The default card type to use when creating a new card. This will be in the form of a URL.
    default_card_type_href: "",

    # URL of the access group
    default_access_group_href: "",

    # the building / organisation code
    default_facility_code: "",

    disabled_card_value: "Disabled (manually)",

    # changes the channel when you want to isolate signals
    door_event_channel: "event",

    # for client certificate authentication
    # https_private_key: "PEM format",
    # https_client_cert: "PEM format",

    # obtain the list of these at: /api/events/groups/
    event_mappings: [
      {
        group:  1,
        action: "tamper",
      },
      {
        group:  18,
        action: "denied",
      },
      {
        group:  19,
        action: "duress",
      },
      {
        # card swipe events for various door / lift types
        group:  23,
        types:  [15800, 15816, 20001, 20002, 20003, 20006, 20047, 41500, 41501, 41520, 41521, 42102, 42415],
        action: "granted",
      },
      {
        # Door status events
        group:  26,
        types:  [23031], # Door Opened
        action: "request_to_exit",
      },
      {
        # "Non-Card Door Unlock"
        group:  27,
        action: "request_to_exit",
      },
      {
        group:  29,
        action: "forced_door",
      },
      {
        group:  47,
        action: "security_breach",
      },
    ],
  })

  record EventMap, group : Int32, types : Array(Int32)?, action : Action do
    include JSON::Serializable
  end

  def on_load
    on_update

    spawn { event_monitor }
    schedule.every(10.minutes) { query_endpoints }
    transport.before_request do |req|
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  def on_unload
    @poll_events = false
  end

  @poll_events : Bool = true
  @api_key : String = ""
  @unique_pdf_name : String = "email"
  @door_event_channel : String = "event"
  @headers : Hash(String, String) = {} of String => String
  @disabled_card_value : String = "Disabled (manually)"
  @event_map : Hash(String, EventMap) = {} of String => EventMap

  def on_update
    uri = URI.parse(config.uri.not_nil!)
    @uri_base ||= "#{uri.scheme}://#{uri.host}"
    api_key = setting(String, :api_key)
    @api_key = "GGL-API-KEY #{api_key}"
    @door_event_channel = setting?(String, :door_event_channel) || "event"

    new_map = {} of String => EventMap
    (setting?(Array(EventMap), :event_mappings) || [] of EventMap).each do |event|
      new_map[event.group.to_s] = event
    end
    @event_map = new_map

    @unique_pdf_name = setting(String, :unique_pdf_name)

    @default_division = setting?(String, :default_division_href)
    @default_facility_code = setting?(String, :default_facility_code)
    @default_card_type = setting?(String, :default_card_type_href)
    @default_access_group = setting?(String, :default_access_group_href)
    @disabled_card_value = setting(String?, :disabled_card_value) || "Disabled (manually)"

    @headers = {
      "Authorization" => @api_key,
      "Content-Type"  => "application/json",
    }
  end

  def connected
    query_endpoints
  end

  getter! uri_base : String
  getter access_groups_endpoint : String = "/api/access_groups"
  getter access_zones_endpoint : String = "/api/access_zones"
  getter alarm_zones_endpoint : String = "/api/alarm_zones"
  getter cardholders_endpoint : String = "/api/cardholders"
  getter divisions_endpoint : String = "/api/divisions"
  getter card_types_endpoint : String = "/api/card_types"
  getter events_endpoint : String = "/api/events"
  getter pdfs_endpoint : String = "/api/personal_data_fields"
  getter doors_endpoint : String = "/api/doors"

  @fixed_pdf_id : String = ""
  @default_division : String? = nil
  @default_facility_code : String? = nil
  @default_card_type : String? = nil
  @default_access_group : String? = nil

  def query_endpoints
    response = get("/api", headers: @headers)
    raise "endpoints request failed with #{response.status_code}\n#{response.body}" unless response.success?
    payload = JSON.parse response.body

    logger.debug { "endpoints query returned:\n#{payload.inspect}" }

    api_version = SemanticVersion.parse(payload["version"].as_s.split('.')[0..2].join('.'))
    raw_uri = payload["features"]["cardholders"]["cardholders"]["href"].as_s
    uri = URI.parse(raw_uri)
    @uri_base = "#{uri.scheme}://#{uri.host}"
    @cardholders_endpoint = get_path raw_uri
    @divisions_endpoint = @cardholders_endpoint.sub("cardholders", "divisions")
    @access_groups_endpoint = get_path payload["features"]["accessGroups"]["accessGroups"]["href"].as_s
    @access_zones_endpoint = get_path payload["features"]["accessZones"]["accessZones"]["href"].as_s
    @alarm_zones_endpoint = get_path(payload.dig("features", "alarmZones", "alarmZones", "href").try(&.as_s) || @alarm_zones_endpoint)
    @events_endpoint = get_path payload["features"]["events"]["events"]["href"].as_s

    # not sure what version of Gallagher this was added
    begin
      @doors_endpoint = get_path payload["features"]["doors"]["doors"]["href"].as_s
    rescue error
      logger.debug(exception: error) { "error locating doors feature URI" }
    end

    if api_version >= SemanticVersion.parse("8.10.0")
      @card_types_endpoint = get_path payload["features"]["cardTypes"]["assign"]["href"].as_s
      @pdfs_endpoint = get_path payload["features"]["personalDataFields"]["personalDataFields"]["href"].as_s
      response = get(@pdfs_endpoint, {"name" => @unique_pdf_name}, @headers)
    else
      @card_types_endpoint = get_path payload["features"]["cardTypes"]["cardTypes"]["href"].as_s
      @pdfs_endpoint = get_path payload["features"]["items"]["items"]["href"].as_s
      response = get(@pdfs_endpoint, {
        "name" => @unique_pdf_name,
        "type" => "33",
      }, @headers)
    end

    if response.success?
      logger.debug { "PDFS request returned:\n#{response.body}" }
    else
      raise "PDFS request failed with #{response.status_code}\n#{response.body}"
    end

    # There should only be one result
    results = JSON.parse(response.body)["results"].as_a
    @fixed_pdf_id = results.first["id"].as_s unless results.empty?
  end

  protected def get_path(uri : String) : String
    URI.parse(uri).request_target.not_nil!
  end

  def get_alarm_zones(name : String? = nil, exact_match : Bool = true)
    # surround the parameter with double quotes for an exact match
    name = %("#{name}") if name && exact_match
    response = get(@alarm_zones_endpoint, headers: @headers, params: {"top" => "10000", "name" => name}.compact)
    raise "alarm zones request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(JSON::Any, response.body)
  end

  ##
  # Personal Data Fields (PDFs) are custom fields that Gallagher allows definintions of on a site-by-site basis.
  # They will usually be for things like email address, employee ID or some other field specific to whoever is hosting the Gallagher instance.
  # Allows retrieval of the PDFs used in the Gallagher instance, primarily so we can get the PDF's ID and use that to filter cardholders based on that PDF.
  #
  # @param name [String] The name of the PDF which we want to retrieve. This will only return one result (as the PDF names are unique).
  # @return [Hash] A list of PDF results and a next link for pagination (we will generally have less than 100 PDFs so 'next' link will mostly be unused):
  # @example An example response:
  #    {
  #      "results": [
  #        {
  #          "name": "email",
  #          "id": "5516",
  #          "href": "https://localhost:8904/api/personal_data_fields/5516"
  #        },
  #        {
  #          "name": "cellphone",
  #          "id": "9998",
  #          "href": "https://localhost:8904/api/personal_data_fields/9998",
  #          "serverDisplayName": "Site B"
  #        }
  #      ],
  #      "next": {
  #        "href": "https://localhost:8904/api/personal_data_fields?pos=900&sort=id"
  #      }
  #    }
  def get_pdfs(name : String? = nil, exact_match : Bool = true)
    # surround the parameter with double quotes for an exact match
    name = %("#{name}") if name && exact_match
    response = get(@pdfs_endpoint, headers: @headers, params: {"top" => "10000", "name" => name}.compact)
    raise "PDFS request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(PDF, response.body)
  end

  def get_pdf(user_id : String, pdf_id : String | UInt64)
    response = get("#{@cardholders_endpoint}/#{user_id}/personal_data/#{pdf_id}", headers: @headers)
    raise "cardholder PDF request failed with #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  def get_base64_pdf(user_id : String, pdf_id : String | UInt64)
    response = get("#{@cardholders_endpoint}/#{user_id}/personal_data/#{pdf_id}", headers: @headers)
    raise "cardholder PDF request failed with #{response.status_code}\n#{response.body}" unless response.success?

    Base64.strict_encode(response.body)
  end

  def get_cardholder(id : String | Int32)
    response = get("#{@cardholders_endpoint}/#{id}", headers: @headers)
    raise "cardholder request failed with #{response.status_code}\n#{response.body}" unless response.success?
    Cardholder.from_json(response.body)
  end

  def query_cardholders(filter : String, pdf_name : String? = nil, exact_match : Bool = true)
    pdf_id = "pdf_" + (pdf_name ? get_pdfs(pdf_name).first.id : @fixed_pdf_id).not_nil!
    query = {
      pdf_id => exact_match ? %("#{filter}") : filter,
      "top"  => "10000",
    }

    response = get(@cardholders_endpoint, query, headers: @headers)
    raise "cardholder query request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(Cardholder, response.body)
  end

  def query_card_types
    response = get(@card_types_endpoint, {"top" => "10000"}, headers: @headers)
    raise "card types request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(CardType, response.body)
  end

  def get_card_type(id : String | Int32 | Nil = nil)
    card = id || @default_card_type || raise("no default card type provided")
    response = get("#{@card_types_endpoint}/#{card}", headers: @headers)
    raise "card type request failed with #{response.status_code}\n#{response.body}" unless response.success?
    CardType.from_json(response.body)
  end

  ##
  # Create a new cardholder.
  # @param first_name [String] The first name of the new cardholder. Either this or last name is required (but we should assume both are for most instances).
  # @param last_name [String] The last name of the new cardholder. Either this or first name is required (but we should assume both are for most instances).
  # @option options [String] :division The division to add the cardholder to. This is required when making the request to create the cardholder but if none is passed the `default_division` is used.
  # @option options [Hash] :pdfs A hash containing all PDFs to add to the user in the form `{ some_pdf_name: some_pdf_value, another_pdf_name: another_pdf_value }`.
  # @option options [Array] :cards An array of cards to be added to this cardholder which can include both virtual and physical cards.
  # @option options [Array] :access_groups An array of access groups to add this cardholder to. These may include `from` and `until` fields to dictate temporary access.
  # @option options [Array] :competencies An array of competencies to add this cardholder to.
  # @return [Hash] The cardholder that was created.
  def create_cardholder(
    first_name : String,
    last_name : String,
    description : String = "a cardholder",
    authorised : Bool = true,
    pdfs : Hash(String, String)? = nil,
    cards : Array(Card)? = nil,
    access_groups : Array(CardholderAccessGroup)? = nil,
    short_name : String? = nil,
    division_href : String? = nil,
  )
    short_name ||= "#{first_name} #{last_name}"
    short_name = short_name[0..15]

    payload = Cardholder.new(
      first_name, last_name, short_name, description, authorised,
      cards, access_groups, division_href || @default_division.not_nil!
    ).to_json

    if pdfs && !pdfs.empty?
      payload = "#{payload[0..-2]},#{pdfs.transform_keys { |key| "@#{key}" }.to_json[1..-1]}"
    end

    response = post(@cardholders_endpoint, headers: @headers, body: payload)
    Cardholder.from_json process(response)
  end

  def update_cardholder(
    id : String | Int32? = nil,
    href : String? = nil,
    first_name : String? = nil,
    last_name : String? = nil,
    description : String? = nil,
    authorised : Bool = true,
    pdfs : Hash(String, String)? = nil,
    cards : Array(Card)? = nil,
    remove_cards : Array(Card)? = nil,
    update_cards : Array(Card)? = nil,
    access_groups : Array(CardholderAccessGroup)? = nil,
    remove_access_groups : Array(CardholderAccessGroup)? = nil,
    update_access_groups : Array(CardholderAccessGroup)? = nil,
    short_name : String? = nil,
    division_href : String? = nil,
  )
    url = href ? get_path(href) : "#{@cardholders_endpoint}/#{id.not_nil!}"

    if cards || remove_cards || update_cards
      card_updates = {} of String => Array(Card)
      card_updates["add"] = cards if cards
      card_updates["update"] = update_cards if update_cards
      if remove_cards
        card_updates["remove"] = remove_cards.map { |card| Card.new(card.href, nil) }
      end
    end

    if access_groups || remove_access_groups || update_access_groups
      groups_update = {} of String => Array(CardholderAccessGroup)
      groups_update["add"] = access_groups if access_groups
      groups_update["update"] = update_access_groups if update_access_groups
      groups_update["remove"] = remove_access_groups if remove_access_groups
    end

    payload = Cardholder.new(
      first_name, last_name, short_name, description, authorised,
      card_updates, groups_update, division_href
    ).to_json

    if pdfs && !pdfs.empty?
      payload = "#{payload[0..-2]},#{pdfs.transform_keys { |key| "@#{key}" }.to_json[1..-1]}"
    end

    response = patch(url, headers: @headers, body: payload)
    result = process(response)
    result.presence && Cardholder.from_json(result)
  end

  def disable_card(href : String)
    uri = get_path(href)
    cardholder_id = uri.split('/')[-3]
    card = Card.new uri, {value: @disabled_card_value, type: nil.as(String?)}
    update_cardholder(cardholder_id, update_cards: [card])
  end

  def delete_card(href : String)
    response = delete(get_path(href), headers: @headers)
    raise "failed to delete card #{href}" unless response.success?
  end

  def cardholder_exists?(filter : String)
    !query_cardholders(filter).empty?
  end

  def remove_cardholder_access(
    id : String? = nil,
    href : String? = nil,
  )
    update_cardholder(id, href, authorised: false)
  end

  def get_access_group(id : String)
    response = get("#{@access_groups_endpoint}/#{id}", headers: @headers)
    raise "access group request failed with #{response.status_code}\n#{response.body}" unless response.success?
    AccessGroup.from_json(response.body)
  end

  def get_access_groups(name : String? = nil, exact_match : Bool = true)
    # surround the parameter with double quotes for an exact match
    name = %("#{name}") if name && exact_match
    response = get(@access_groups_endpoint, headers: @headers, params: {"top" => "10000", "name" => name}.compact)
    raise "access groups request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(AccessGroup, response.body)
  end

  def get_access_group_members(id : String)
    response = get("#{@access_groups_endpoint}/#{id}/cardholders", headers: @headers)
    raise "access group members request failed with #{response.status_code}\n#{response.body}" unless response.success?
    json = response.body
    begin
      NamedTuple(cardholders: Array(NamedTuple(href: String?, cardholder: NamedTuple(name: String, href: String?)))).from_json(json)
    rescue error
      logger.warn(exception: error) { "#get_access_group_members failed to parse:\n#{json}" }
    end
  end

  def access_group_member?(group_id : String | Int32, cardholder_id : String | Int32) : String?
    group_id = group_id.to_s
    details = get_cardholder(cardholder_id).access_groups
    access_groups = case details
                    in Array(CardholderAccessGroup)
                      details
                    in Hash(String, Array(CardholderAccessGroup))
                      details.values.flatten
                    in Nil
                      return nil
                    end

    access = access_groups.find do |group|
      if href = group.access_group[:href]
        href.ends_with?(group_id)
      end
    end

    access.try(&.href)
  end

  def remove_access_group_member(group_id : String | Int32, cardholder_id : String | Int32) : Bool
    if href = access_group_member?(group_id, cardholder_id)
      response = delete(get_path(href), headers: @headers)
      raise "remove access group member request failed with #{response.status_code}\n#{response.body}" unless response.success?
      true
    else
      false
    end
  end

  def add_access_group_member(group_id : String | Int32, cardholder_id : String | Int32, from_unix : Int64? = nil, until_unix : Int64? = nil)
    from_time = Time.unix(from_unix) if from_unix
    until_time = Time.unix(until_unix) if until_unix
    group = CardholderAccessGroup.new({href: "#{@uri_base}#{@access_groups_endpoint}/#{group_id}".as(String?), name: nil.as(String?)})
    update_cardholder(cardholder_id, access_groups: [group])
  end

  def get_division(id : String)
    response = get("#{@divisions_endpoint}/#{id}", headers: @headers)
    raise "division request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def get_divisions(name : String? = nil, exact_match : Bool = true)
    # surround the parameter with double quotes for an exact match
    name = %("#{name}") if name && exact_match
    response = get(@divisions_endpoint, headers: @headers, params: {"top" => "10000", "name" => name}.compact)
    raise "divisions request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(JSON::Any, response.body)
  end

  def get_zones(name : String? = nil, exact_match : Bool = true)
    # surround the parameter with double quotes for an exact match
    name = %("#{name}") if name && exact_match
    response = get(@access_zones_endpoint, headers: @headers, params: {"top" => "10000", "name" => name}.compact)
    raise "zones request failed with #{response.status_code}\n#{response.body}" unless response.success?
    get_results(JSON::Any, response.body)
  end

  # forces a zone to be free, that is doors are unlocked
  @[Security(Level::Support)]
  def free_zone(zone_id : String | Int32) : Bool?
    response = post("#{@access_zones_endpoint}/#{zone_id}/free", headers: @headers)
    response.success?
  end

  # forces a zone to be secure and require a swipe card to access
  @[Security(Level::Support)]
  def secure_zone(zone_id : String | Int32) : Bool?
    response = post("#{@access_zones_endpoint}/#{zone_id}/secure", headers: @headers)
    response.success?
  end

  # returns the zone to it's default scheduled state, removing any overrides
  @[Security(Level::Support)]
  def reset_zone(zone_id : String | Int32) : Bool?
    response = post("#{@access_zones_endpoint}/#{zone_id}/cancel", headers: @headers)
    response.success?
  end

  # returns the zone details
  @[Security(Level::Support)]
  def get_access_zone(zone_id : String | Int32) : JSON::Any
    response = get("#{@access_zones_endpoint}/#{zone_id}", headers: @headers)
    raise "zone request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def get_events
    response = get(@events_endpoint, headers: @headers)
    raise "events request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  def get_event_groups
    response = get("#{@events_endpoint}/groups", headers: @headers)
    raise "event groups request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  macro get_results(klass, response)
    %body = {{response}}
    begin
      %results = Results({{klass}}).from_json %body
      %result_array = %results.results
      loop do
        %next_uri = %results.next_uri
        break unless %next_uri
        %body = get_raw(%next_uri[:href])
        %results = Results({{klass}}).from_json(%body)
        %result_array.concat %results.results
      end
      %result_array
    rescue error
      logger.debug { "failed to parse response body:\n#{%body}\n" }
      raise error
    end
  end

  protected def get_raw(href : String)
    response = get(get_path(href), headers: @headers)
    raise "raw request failed with #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  @[Security(Level::Support)]
  def get_href(href : String)
    response = get(get_path(href), headers: @headers)
    raise "generic request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

  @[Security(Level::Support)]
  def delete_href(href : String)
    delete_card(href)
  end

  protected def process(response) : String
    if response.status.created?
      response = get(get_path(response.headers["Location"]), headers: @headers)
    end

    case response.status
    when .bad_request?
      # TODO:: check for card number in use and card number out of range
      raise BadRequest.new("request failed with #{response.status_code}\n#{response.body}")
    when .not_found?
      raise NotFound.new("request failed with #{response.status_code}\n#{response.body}")
    when .conflict?
      raise Conflict.new("request failed with #{response.status_code}\n#{response.body}")
    else
      raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
    end

    response.body
  end

  class Conflict < Exception; end

  class NotFound < Exception; end

  class BadRequest < Exception; end

  def doors
    response = get(@doors_endpoint, headers: @headers)
    raise "cardholder PDF request failed with #{response.status_code}\n#{response.body}" unless response.success?
    NamedTuple(results: Array(DoorDetails)).from_json(response.body)[:results]
  end

  def door(id : String | Int64)
    response = get("#{@doors_endpoint}/#{id}", headers: @headers)
    raise "door lookup request failed with #{response.status_code}\n#{response.body}" unless response.success?
    DoorDetails.from_json(response.body)
  end

  # =======================
  # Door Security Interface
  # =======================

  # user id => email
  @user_email_cache : Hash(String, String?) = {} of String => String?

  def get_cardholder_email(user_id : String?) : String?
    return nil unless user_id

    if @user_email_cache.has_key? user_id
      return @user_email_cache[user_id]
    end

    details = get_cardholder(user_id)
    email_key = "@#{@unique_pdf_name}"
    @user_email_cache[user_id] = details.json_unmapped[email_key]?.try(&.as_s)
  rescue error
    logger.warn(exception: error) { "failed to lookup email for user: #{user_id}" }
    nil
  end

  def door_list : Array(Door)
    doors.map { |d| Door.new(d.id, d.name) }
  end

  def alarm_zones
    get_alarm_zones.map { |d| Door.new(d["id"].as_s, d["name"].as_s) }
  end

  @[Security(Level::Support)]
  def unlock(door_id : String) : Bool?
    response = post("#{@doors_endpoint}/#{door_id}/open", headers: @headers)
    response.success?
  end

  protected def event_monitor
    uri = URI.parse(config.uri.not_nil!)
    uri.path = @events_endpoint
    uri.query = "after=#{Time.utc.to_rfc3339}"

    sleep 2.seconds

    loop do
      break unless @poll_events

      begin
        logger.debug { "checking for events #{uri.request_target}" }

        response = get(uri.request_target, headers: @headers, concurrent: true)
        if response.success?
          logger.debug { "new event: #{response.body}" }
          events_resp = Events.from_json(response.body)

          update_url = URI.parse(events_resp.update_url)
          uri.path = update_url.path
          uri.query = update_url.query

          events = events_resp.events
          next if events.empty?
          events.each do |event|
            if mapped = @event_map[event.group.id]?
              if event.matching_type? mapped.types
                publish("security/#{@door_event_channel}/door", DoorEvent.new(
                  module_id: module_id,
                  security_system: "Gallagher",
                  door_id: event.source.id,
                  action: mapped.action,
                  card_id: event.card.try &.number,
                  user_name: event.cardholder.try &.name,
                  user_email: get_cardholder_email(event.cardholder.try &.id)
                ).to_json)
              end
            end
          end
        else
          # we don't want to thrash the server
          logger.warn { "event polling failed with\nStatus #{response.status_code}\n#{response.body}" }
          sleep 2.seconds
        end
      rescue timeout : IO::TimeoutError
        # if no events came in for 2min (default timeout), 10 seconds to account for server clock drift
        last_event = 10.second.ago
        logger.debug { "no events detected" }
      rescue error
        logger.warn(exception: error) { "monitoring for events" }
        # jump over anything that potentially caused the error
        sleep 1.second
        last_event = 1.second.from_now
      end
    end
  end

  # ==============================
  # Zone Access Security Interface
  # ==============================

  alias CardHolderDetails = PlaceOS::Driver::Interface::ZoneAccessSecurity::CardHolderDetails
  alias ZoneDetails = PlaceOS::Driver::Interface::ZoneAccessSecurity::ZoneDetails

  struct CardHolder < CardHolderDetails
    def initialize(@id, @name, @email)
    end
  end

  struct ZoneInfo < ZoneDetails
    def initialize(@id, @name, @description)
    end
  end

  # using an email address, lookup the security system id for a user
  @[Security(Level::Support)]
  def card_holder_id_lookup(email : String) : String | Int64 | Nil
    query_cardholders(email, @unique_pdf_name).first?.try(&.id)
  end

  # given a card holder id, lookup the details of the card holder
  def card_holder_lookup(id : String | Int64) : CardHolderDetails
    details = get_cardholder(id.to_s)
    first_name = details.first_name
    last_name = details.last_name
    short_name = details.short_name
    name = if first_name.presence
             "#{first_name} #{last_name}"
           else
             short_name || ""
           end
    email_key = "@#{@unique_pdf_name}"
    CardHolder.new(id, name, details.json_unmapped[email_key]?.try(&.as_s))
  end

  # using a name, lookup the access zone id
  @[Security(Level::Support)]
  def zone_access_id_lookup(name : String, exact_match : Bool = true) : String | Int64 | Nil
    get_access_groups(name, exact_match).first?.try(&.id)
  end

  # given an access zone id, lookup the details of the zone
  def zone_access_lookup(id : String | Int64) : ZoneDetails
    details = get_access_group(id.to_s)
    ZoneInfo.new(id, details.name, details.description)
  end

  # return the id that represents the access permission (truthy indicates access)
  @[Security(Level::Support)]
  def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64) : String | Int64 | Nil
    access_group_member?(zone_id.to_s, card_holder_id.to_s)
  end

  # add a member to the zone
  @[Security(Level::Support)]
  def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    add_access_group_member(zone_id.to_s, card_holder_id.to_s, from_unix, until_unix)
  end

  # remove a member from the zone
  @[Security(Level::Support)]
  def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64)
    remove_access_group_member zone_id.to_s, card_holder_id.to_s
  end
end
