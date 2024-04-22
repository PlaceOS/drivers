require "placeos-driver"
require "placeos-driver/interface/door_security"

require "xml"

# https://integriti-api.innerrange.com/API/v2/doc/

class InnerRange::Integriti < PlaceOS::Driver
  include Interface::DoorSecurity

  descriptive_name "Inner Range Integriti Security System"
  generic_name :Integriti
  uri_base "https://integriti-api.innerrange.com/restapi"

  default_settings({
    basic_auth: {
      username: "installer",
      password: "installer",
    },
    api_key:             "api-access-key",
    default_unlock_time: 10,
    default_site_id:     1,
  })

  def on_load
    on_update
  end

  def on_update
    api_key = setting?(String, :api_key) || ""

    transport.before_request do |request|
      request.headers["API-KEY"] = api_key
      request.headers["Accept"] = "application/xml"
      request.headers["Content-Type"] = "application/xml"
    end

    @default_unlock_time = setting?(Int32, :default_unlock_time) || 10
    @default_site_id = setting?(Int32, :default_site_id) || 1
  end

  getter default_unlock_time : Int32 = 10
  getter default_site_id : Int32 = 1

  macro check(response)
    begin
      %resp = {{response}}
      raise "request failed with #{%resp.status_code} (#{%resp.body})" unless %resp.success?
      %body = %resp.body
      logger.debug { "response was:\n#{%body}" }
      begin
        XML.parse %body
      rescue error
        logger.error { "error: #{error.message}, failed to parse:\n#{%body}" }
        raise error
      end
    end
  end

  PROPS = {} of String => String

  macro define_xml_type(klass, keys, lookup = nil)
    alias {{klass}} = NamedTuple(
      {% for _node, variable in keys %}
        {{ variable.var }}: {{ variable.type }},
      {% end %}
    )

    {% PROPS[lookup || klass.stringify] = keys.keys.join(",") %}

    protected def extract_{{klass.id.stringify.underscore.id}}(document : XML::Node) : {{klass}}
      {% for _node, variable in keys %}
        {% resolved_type = variable.type.resolve %}
        {% if resolved_type == Int32 %}
          var_{{ variable.var }} = 0
        {% elsif resolved_type == Int64 %}
          var_{{ variable.var }} = 0_i64
        {% elsif resolved_type == Bool %}
          var_{{ variable.var }} = false
        {% elsif resolved_type == Float64 %}
          var_{{ variable.var }} = 0.0
        {% elsif resolved_type.stringify.starts_with? "NamedTuple" %}
          var_{{ variable.var }} = uninitialized {{resolved_type}}
        {% else %}
          var_{{ variable.var }} = ""
        {% end %}
      {% end %}

      if %data = document.document? ? document.first_element_child : document
        {% for node, variable in keys %}
          {% if node.starts_with? "attr_" %}
            {% attribute_name = node.split("_")[1] %}
            %content = %data[{{attribute_name}}]? || ""

            {% resolved_type = variable.type.resolve %}
            {% if resolved_type == Int32 %}
              var_{{ variable.var }} = %content.to_i? || 0
            {% elsif resolved_type == Int64 %}
              var_{{ variable.var }} = %content.to_i64? || 0_i64
            {% elsif resolved_type == Bool %}
              var_{{ variable.var }} = %content.downcase == "true"
            {% elsif resolved_type == Float64 %}
              var_{{ variable.var }} = %content.to_f? || 0.0
            {% elsif resolved_type.stringify.starts_with? "NamedTuple" %}
              var_{{ variable.var }} = extract_{{variable.type.stringify.underscore.id}}(child)
            {% else %}
              var_{{ variable.var }} = %content
            {% end %}
          {% end %}
        {% end %}

        %data.children.select(&.element?).each do |child|
          case child.name
          {% for node, variable in keys %}
          when {{node.id.stringify}}
            %content = child.content || ""

            {% resolved_type = variable.type.resolve %}
            {% if resolved_type == Int32 %}
              var_{{ variable.var }} = %content.to_i? || 0
            {% elsif resolved_type == Int64 %}
              var_{{ variable.var }} = %content.to_i64? || 0_i64
            {% elsif resolved_type == Bool %}
              var_{{ variable.var }} = %content.downcase == "true"
            {% elsif resolved_type == Float64 %}
              var_{{ variable.var }} = %content.to_f? || 0.0
            {% elsif resolved_type.stringify.starts_with? "NamedTuple" %}
              var_{{ variable.var }} = extract_{{variable.type.stringify.underscore.id}}(child)
            {% else %}
              var_{{ variable.var }} = %content
            {% end %}
          {% end %}
          end
        end
      end

      {
        {% for node, variable in keys %}
          {{ variable.var }}: var_{{ variable.var }},
        {% end %}
      }
    end
  end

  alias Filter = Hash(String, String | Bool | Int64 | Int32 | Float64 | Float32 | Nil)

  def build_filter(filter : Filter) : String
    XML.build(indent: "  ") do |xml|
      xml.element("FilterExpression", {
        "xmlns:xsd" => "http://www.w3.org/2001/XMLSchema",
        "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance",
        "xsi:type"  => "AggregateExpression",
      }) do
        # xml.element("OperatorType") { xml.text "Or" }
        xml.element("OperatorType") { xml.text "And" }
        xml.element("SubExpressions") do
          filter.each do |key, value|
            xml.element("FilterExpression", {
              "xsi:type" => "PropertyExpression",
            }) do
              xml.element("PropertyName") { xml.text key }
              # also supports: Greater, Less
              xml.element("OperatorType") { xml.text "Equals" }
              xml.element("Args") do
                compare_type = case value
                               in String
                                 "xsd:string"
                               in Bool
                                 "xsd:boolean"
                               in Int32
                                 "xsd:int"
                               in Int64
                                 "xsd:long"
                               in Float32
                                 "xsd:float"
                               in Float64
                                 "xsd:double"
                               in Nil
                                 raise "nil values not supported"
                               end

                xml.element("anyType", {
                  "xsi:type" => compare_type,
                }) do
                  xml.text value.to_s
                end
              end
            end
          end
        end
      end
    end
  end

  # &FullObject=true doesn't work for cards annoyingly...
  protected def prop_param(type : String)
    if props = PROPS[type]?
      "AdditionalProperties=#{props}"
    else
      "FullObject=true"
    end
  end

  protected def paginate_request(category : String, type : String, filter : Filter = Filter.new, &)
    filter.compact!

    next_page = if filter.empty?
                  "/v2/#{category}/#{type}?PageSize=1000&#{prop_param(type)}"
                else
                  body = build_filter(filter)
                  "/v2/#{category}/GetFilteredEntities/#{type}?PageSize=1000&#{prop_param(type)}"
                end

    loop do
      document = if filter.empty?
                   check get(next_page)
                 else
                   check post(next_page, body: body)
                 end

      page_size = 0
      next_page = ""
      rows_returned = 0

      if data = document.first_element_child
        data.children.select(&.element?).each do |child|
          case child.name
          when "PageSize"
            page_size = (child.content || "0").to_i
          when "NextPageUrl"
            next_page = URI.decode(child.content || "")
          when "Rows"
            if rows = child.children.select(&.element?)
              rows_returned = rows.size
              rows.each do |node|
                yield node
              end
            end
          end
        end
      end

      break if next_page.empty? || rows_returned < page_size
    end
  end

  # <ApiVersion>http://20.213.104.2:80/restapi/ApiVersion/v2</ApiVersion>
  def api_version : String
    document = check get("/ApiVersion")
    uri = URI.parse document.first_element_child.try(&.content).as(String)
    Path[uri.path].basename
  end

  # ===========
  # SYSTEM INFO
  # ===========

  define_xml_type(SystemInfo, {
    "ProductEdition"  => edition : String,
    "ProductVersion"  => version : String,
    "ProtocolVersion" => protocol : Int32,
  })

  def system_info
    document = check get("/v2/SystemInfo")
    extract_system_info(document)
  end

  # =====
  # SITES
  # =====

  define_xml_type(Site, {
    "ID"          => id : Int32,
    "Name"        => name : String,
    "PartitionID" => partition_id : Int32,
  }, "SiteKeyword")

  # roughly analogous to buildings
  def sites : Array(Site)
    sites = [] of Site
    paginate_request("BasicStatus", "SiteKeyword") do |row|
      sites << extract_site(row)
    end
    sites
  end

  def site(id : Int64 | String)
    document = check get("/v2/BasicStatus/SiteKeyword/#{id}?#{prop_param "SiteKeyword"}")
    extract_site(document)
  end

  # =====
  # AREAS
  # =====

  define_xml_type(Area, {
    "ID"   => id : Int64,
    "Name" => name : String,
    "Site" => site : Site,
  })

  # roughly zones in a building
  def areas(site_id : Int32? = nil)
    areas = [] of Area
    filter = Filter{
      "Site.ID" => site_id,
    }
    paginate_request("BasicStatus", "Area", filter) do |row|
      areas << extract_area(row)
    end
    areas
  end

  def area(id : Int64 | String)
    document = check get("/v2/BasicStatus/Area/#{id}?#{prop_param "Area"}")
    extract_area(document)
  end

  # ==========
  # Partitions
  # ==========

  define_xml_type(Partition, {
    "ID"          => id : Int32,
    "Name"        => name : String,
    "ParentId"    => parent_id : Int32,
    "PartitionId" => partition_id : Int32,
    "ShortName"   => short_name : String,
  })

  # doors on a site
  def partitions(parent_id : Int32? = nil)
    partitions = [] of Partition
    filter = Filter{
      "ParentId" => parent_id,
    }
    paginate_request("BasicStatus", "Partition", filter) do |row|
      partitions << extract_partition(row)
    end
    partitions
  end

  def partition(id : Int64 | String)
    document = check get("/v2/BasicStatus/Partition/#{id}?#{prop_param "Partition"}")
    extract_partition(document)
  end

  # =====
  # Users
  # =====

  define_xml_type(User, {
    "ID"               => id : Int64,
    "Name"             => name : String,
    "SiteID"           => site_id : Int32,
    "SiteName"         => site_name : String,
    "Address"          => address : String,
    "attr_PartitionID" => partition_id : Int32,
    "cf_EmailAddress"  => email : String,
  })

  # users in a site
  def users(site_id : Int32? = nil, email : String? = nil)
    users = [] of User
    filter = Filter{
      "SiteID"          => site_id,
      "cf_EmailAddress" => email,
    }
    paginate_request("BasicStatus", "User", filter) do |row|
      users << extract_user(row)
    end
    users
  end

  def user(id : Int64 | String)
    document = check get("/v2/BasicStatus/User/#{id}?#{prop_param "User"}")
    extract_user(document)
  end

  # =====
  # Doors
  # =====

  define_xml_type(Card, {
    "ID"                                  => id : String,
    "Name"                                => name : String,
    "CardNumberNumeric"                   => card_number_numeric : Int64,
    "CardNumber"                          => card_number : String,
    "CardSerialNumber"                    => card_serial_number : String,
    "IssueNumber"                         => issue_number : Int32,
    # Active, ActiveExpiring, ActiveReplacement seem to be the only active states
    "State"                               => state : String,
    "ExpiryDateTime"                      => expiry : String,
    "StartDateTime"                       => valid_from : String,
    "LastUsed"                            => last_used : String,
    "CloudCredentialId"                   => cloud_credential_id : String,
    # None or HIDMobileCredential
    "CloudCredentialType"                 => cloud_credential_type : String,
    "CloudCredentialPoolId"               => cloud_credential_pool_id : String,
    "CloudCredentialInvitationId"         => cloud_credential_invite_id : String,
    "CloudCredentialInvitationCode"       => cloud_credential_invite_code : String,
    "CloudCredentialCommunicationHandler" => cloud_credential_comms_handler : String,
    "ManagedByActiveDirectory"            => active_directory : Bool,
    # these are Ref types...
    # define a special ref types that extracts attributes
    # "Site" => site : Site,
    # "User" => user : User,
  })

  def cards(site_id : Int32? = nil)
    cards = [] of Card
    filter = Filter{
      "Site.ID" => site_id,
    }
    paginate_request("VirtualCardBadge", "Card", filter) do |row|
      cards << extract_card(row)
    end
    cards
  end

  def card(id : Int64 | String)
    document = check get("/v2/VirtualCardBadge/Card/#{id}?#{prop_param "Card"}")
    extract_card(document)
  end

  # =====
  # Doors
  # =====

  define_xml_type(IntegritiDoor, {
    "ID"   => id : Int64,
    "Name" => name : String,
    "Site" => site : Site,
  }, "Door")

  # doors on a site
  def doors(site_id : Int32? = nil)
    doors = [] of IntegritiDoor
    filter = Filter{
      "Site.ID" => site_id,
    }
    paginate_request("BasicStatus", "Door", filter) do |row|
      doors << extract_integriti_door(row)
    end
    doors
  end

  def door(id : Int64 | String)
    document = check get("/v2/BasicStatus/Door/#{id}?#{prop_param "Door"}")
    extract_integriti_door(document)
  end

  # =======================
  # Door Security Interface
  # =======================

  @[PlaceOS::Driver::Security(Level::Support)]
  def door_list : Array(Door)
    doors(default_site_id).map do |door|
      Door.new(door[:id].to_s, door[:name])
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def unlock(door_id : String) : Bool?
    payload = XML.build(indent: "  ") do |xml|
      xml.element("GrantAccessActionOptions") do
        xml.element("UnlockSeconds") { xml.text default_unlock_time.to_s }
        # If true, access will be granted even if the Door has been overridden.
        xml.element("ForceEvenIfOverridden") { xml.text "false" }
      end
    end

    response = post("/v2/BasicStatus/GrantAccess/#{door_id}", body: payload)
    response.success?
  end
end
