require "uri"
require "placeos-driver"
require "semantic_version"
require "./rest_api_models"
require "base64"

# Documentation: https://aca.im/driver_docs/Gallagher/Gallagher_CC_REST_API_Docs%208.10.1113.zip

class Gallagher::RestAPI < PlaceOS::Driver
  # Discovery Information
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
  })

  def on_load
    on_update

    schedule.every(1.minutes) { query_endpoints }
    transport.before_request do |req|
      logger.debug { "requesting #{req.method} #{req.path}?#{req.query}\n#{req.headers}\n#{req.body}" }
    end
  end

  @api_key : String = ""
  @unique_pdf_name : String = "email"
  @headers : Hash(String, String) = {} of String => String
  @disabled_card_value : String = "Disabled (manually)"

  def on_update
    api_key = setting(String, :api_key)
    @api_key = "GGL-API-KEY #{api_key}"
    @unique_pdf_name = setting(String, :unique_pdf_name)

    @default_division = setting(String?, :default_division_href)
    @default_facility_code = setting(String?, :default_facility_code)
    @default_card_type = setting(String?, :default_card_type_href)
    @default_access_group = setting(String?, :default_access_group_href)
    @disabled_card_value = setting(String?, :disabled_card_value) || "Disabled (manually)"

    @headers = {
      "Authorization" => @api_key,
      "Content-Type"  => "application/json",
    }
  end

  def connected
    query_endpoints
  end

  @access_groups_endpoint : String = "/api/access_groups"
  @cardholders_endpoint : String = "/api/cardholders"
  @divisions_endpoint : String = "/api/divisions"
  @card_types_endpoint : String = "/api/card_types"
  @events_endpoint : String = "/api/events"
  @pdfs_endpoint : String = "/api/personal_data_fields"
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
    @cardholders_endpoint = get_path payload["features"]["cardholders"]["cardholders"]["href"].as_s
    @divisions_endpoint = @cardholders_endpoint.sub("cardholders", "divisions")
    @access_groups_endpoint = get_path payload["features"]["accessGroups"]["accessGroups"]["href"].as_s
    @events_endpoint = get_path payload["features"]["events"]["events"]["href"].as_s

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

    raise "PDFS request failed with #{response.status_code}\n#{response.body}" unless response.success?

    # There should only be one result
    @fixed_pdf_id = JSON.parse(response.body)["results"][0]["id"].as_s
  end

  protected def get_path(uri : String) : String
    URI.parse(uri).request_target.not_nil!
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

  def get_cardholder(id : String)
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
    division_href : String? = nil
  )
    short_name ||= "#{first_name} #{last_name}"

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
    id : String? = nil,
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
    division_href : String? = nil
  )
    url = href ? get_path(href) : "#{@cardholders_endpoint}/#{id.not_nil!}"

    if cards || remove_cards || update_cards
      card_updates = {} of String => Array(Card)
      card_updates["add"] = cards if cards
      card_updates["update"] = update_cards if update_cards
      card_updates["remove"] = remove_cards if remove_cards
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
    href : String? = nil
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
    get_results(AccessGroupMembership, response.body)
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

  macro get_results(klass, response)
    %results = Results({{klass}}).from_json {{response}}
    %result_array = %results.results
    loop do
      %next_uri = %results.next_uri
      break unless %next_uri
      %results = Results({{klass}}).from_json(get_raw(%next_uri[:href]))
      %result_array.concat %results.results
    end
    %result_array
  end

  protected def get_raw(href : String)
    response = get(get_path(href), headers: @headers)
    raise "raw request failed with #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  def get_href(href : String)
    response = get(get_path(href), headers: @headers)
    raise "generic request failed with #{response.status_code}\n#{response.body}" unless response.success?
    JSON.parse(response.body)
  end

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
end
