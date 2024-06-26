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

    custom_field_hid_origo: "cf_HasVirtualCard",
    custom_field_email:     "cf_EmailAddress",
    custom_field_phone:     "cf_Mobile",
  })

  def on_load
    on_update
  end

  def on_update
    api_key = setting?(String, :api_key) || ""
    @cf_origo = setting?(String, :custom_field_hid_origo) || "cf_HasVirtualCard"
    @cf_email = setting?(String, :custom_field_email) || "cf_EmailAddress"
    @cf_phone = setting?(String, :custom_field_phone) || "cf_Mobile"

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
  getter cf_email : String = "cf_EmailAddress"
  getter cf_phone : String = "cf_Mobile"
  getter cf_origo : String = "cf_HasVirtualCard"

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

  abstract struct IntegritiObject
    include JSON::Serializable
  end

  macro define_xml_type(klass, keys, lookup = nil)
    struct {{klass}} < IntegritiObject
      {% for _node, variable in keys %}
        getter! {{ variable.var }} : {{ variable.type }}
      {% end %}

      def initialize(
        {% for _node, variable in keys %}
          @{{ variable.var }} = nil,
        {% end %}
      )
      end
    end

    {% PROPS[lookup || klass.stringify] = keys.keys.join(",") %}

    protected def extract_{{klass.id.stringify.underscore.id}}(document : XML::Node) : {{klass}}
      {% for _node, variable in keys %}
        var_{{ variable.var }} = nil
      {% end %}

      if %data = document.document? ? document.first_element_child : document
        {% for node, variable in keys %}
          {% if node.starts_with? "attr_" %}
            {% attribute_name = node.split("_")[1] %}
            if %content = %data[{{attribute_name}}]?

              # extract the data
              {% resolved_type = variable.type.resolve %}
              {% variable_var = variable.var %}
              {% if resolved_type == Int32 %}
                var_{{ variable_var }} = %content.to_i?
              {% elsif resolved_type == Int64 %}
                var_{{ variable_var }} = %content.to_i64?
              {% elsif resolved_type == Bool %}
                var_{{ variable_var }} = %content.downcase == "true"
              {% elsif resolved_type == Float64 %}
                var_{{ variable_var }} = %content.to_f?
              {% elsif resolved_type.superclass == IntegritiObject %}
                var_{{ variable_var }} = extract_{{variable.type.stringify.underscore.id}}(child)
              {% else %}
                var_{{ variable_var }} = %content
              {% end %}
            else
              var_{{ variable_var }} = nil
            end
          {% end %}
        {% end %}

        %data.children.select(&.element?).each do |child|
          case child.name
          when "Ref"
            # minimal data provided in attributes
            {% for node, variable in keys %}
              {% if node.starts_with? "attr_" %}
                {% attribute_name = node.split("_")[1] %}
              {% else %}
                {% attribute_name = node %}
              {% end %}

              # ID in ref's are actually the Address in objects
              {% if attribute_name == "Address" %}
                {% attribute_name = "ID" %}
              {% end %}

              if %content = child[{{attribute_name}}]?
                # extract the data
                {% resolved_type = variable.type.resolve %}
                {% variable_var = variable.var %}

                {% if resolved_type == Int32 %}
                  var_{{ variable_var }} = %content.to_i?
                {% elsif resolved_type == Int64 %}
                  var_{{ variable_var }} = %content.to_i64?
                {% elsif resolved_type == Bool %}
                  var_{{ variable_var }} = %content.downcase == "true"
                {% elsif resolved_type == Float64 %}
                  var_{{ variable_var }} = %content.to_f?
                {% elsif resolved_type.superclass == IntegritiObject %}
                  var_{{ variable_var }} = extract_{{variable.type.stringify.underscore.id}}(child)
                {% else %}
                  var_{{ variable_var }} = %content
                {% end %}
              else
                var_{{ variable_var }} = nil
              end
            {% end %}
          {% for node, variable in keys %}
            {% if node.starts_with? "cf_" %}
            # handle custom fields using accessors
            when {{node.id}}
            {% else %}
            when {{node.id.stringify}}
            {% end %}

            if %content = child.content
              # extract the data
              {% resolved_type = variable.type.resolve %}
              {% variable_var = variable.var %}
              {% if resolved_type == Int32 %}
                var_{{ variable_var }} = %content.to_i?
              {% elsif resolved_type == Int64 %}
                var_{{ variable_var }} = %content.to_i64?
              {% elsif resolved_type == Bool %}
                var_{{ variable_var }} = %content.downcase == "true"
              {% elsif resolved_type == Float64 %}
                var_{{ variable_var }} = %content.to_f?
              {% elsif resolved_type.superclass == IntegritiObject %}
                var_{{ variable_var }} = extract_{{variable.type.stringify.underscore.id}}(child)
              {% else %}
                var_{{ variable_var }} = %content
              {% end %}
            else
              var_{{ variable_var }} = nil
            end
          {% end %}
          end
        end
      end

      {{klass}}.new(
        {% for node, variable in keys %}
          {{ variable.var }}: var_{{ variable.var }},
        {% end %}
      )
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
            next if value.nil?

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
  protected def prop_param(type : String, summary_only : Bool = false)
    return "" if summary_only
    if props = PROPS[type]?
      "AdditionalProperties=#{props}"
    else
      "FullObject=true"
    end
  end

  protected def paginate_request(category : String, type : String, filter : Filter = Filter.new, summary_only : Bool = false, &)
    filter.compact!

    next_page = if filter.empty?
                  "/v2/#{category}/#{type}?PageSize=1000&#{prop_param(type, summary_only)}"
                else
                  body = build_filter(filter)
                  "/v2/#{category}/GetFilteredEntities/#{type}?PageSize=1000&#{prop_param(type, summary_only)}"
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

  # =======================
  # Collection Modification
  # =======================
  # these are special routes for adding or removing items from collections
  # use XML.build_fragment as errors if there is a version header: <?xml version="1.0"?>

  @[PlaceOS::Driver::Security(Level::Support)]
  def add_to_collection(type : String, id : String, property_name : String, payload : String)
    check patch("/v2/User/#{type}/#{id}/#{property_name}/addToCollection?IncludeObjectInResult=true", body: payload)
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def remove_from_collection(type : String, id : String, property_name : String, payload : String)
    check patch("/v2/User/#{type}/#{id}/#{property_name}/removeFromCollection?IncludeObjectInResult=true", body: payload)
  end

  protected def modify_collection(type : String, id : String, property_name : String, payload : String, *, add : Bool = true)
    if add
      add_to_collection(type, id, property_name, payload)
    else
      remove_from_collection(type, id, property_name, payload)
    end
  end

  struct Ref
    include JSON::Serializable

    getter type : String
    getter id : String
    getter partition_id : String | Int32? = nil

    def initialize(@type, @id, @partition_id = nil)
    end

    def to_xml(xml)
      xml.element("Ref", {
        "Type"        => type,
        "PartitionID" => partition_id,
        "ID"          => id,
      }.compact!)
    end
  end

  # =======================
  # Add or Update DB entry
  # =======================

  define_xml_type(AddOrUpdateResult, {
    "ID"      => id : Int64,
    "Address" => address : String,
    "Message" => message : String,
  })

  alias UpdateFields = Hash(String, String | Float64 | Int64 | Bool | Ref | Nil)

  # This is the only way to add or update a database entry...
  @[PlaceOS::Driver::Security(Level::Support)]
  def add_or_update(payload : String, return_object : Bool = false)
    if return_object
      check post("/v2/User/AddOrUpdate?IncludeObjectInResult=true", body: payload)
    else
      check post("/v2/User/AddOrUpdate", body: payload)
    end
  end

  protected def add(type : String, return_object : Bool = false, &)
    payload = XML.build_fragment(indent: "  ") do |xml|
      xml.element(type) { yield xml }
    end
    add_or_update payload, return_object: return_object
  end

  protected def apply_fields(xml, fields)
    fields.each do |key, value|
      case value
      when Nil
        xml.element(key)
      when Ref
        xml.element(key) { value.to_xml(xml) }
      else
        value_str = case value
                    when Bool
                      value ? "True" : "False"
                    else
                      value.to_s
                    end
        xml.element(key) { xml.text value_str }
      end
    end
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def add_entry(type : String, fields : UpdateFields, return_object : Bool = false)
    add(type, return_object) { |xml| apply_fields(xml, fields) }
  end

  protected def update(type : String, id : String, attribute : String = "Address", return_object : Bool = false, &)
    payload = XML.build_fragment(indent: "  ") do |xml|
      xml.element(type, {attribute => id}) { yield xml }
    end
    add_or_update payload, return_object: return_object
  end

  # use this to update fields in various models, like:
  # update_entry(type: "User", id: "U5", fields: {cf_HasMobileCredential: true})
  @[PlaceOS::Driver::Security(Level::Support)]
  def update_entry(type : String, id : String, fields : UpdateFields, attribute : String = "Address", return_object : Bool = false)
    update(type, id, attribute, return_object) { |xml| apply_fields(xml, fields) }
  end

  # =================
  # Permission Groups
  # =================

  define_xml_type(PermissionGroup, {
    "attr_PartitionID" => partition_id : Int32,
    "SiteName"         => site_name : String,
    "SiteID"           => site_id : Int32,
    "ID"               => id : Int64,
    "Name"             => name : String,
    "Address"          => address : String,
  })

  def permission_groups(site_id : Int32? = nil) : Array(PermissionGroup)
    pgroups = [] of PermissionGroup
    filter = Filter{
      "Site.ID" => site_id,
    }
    paginate_request("User", "PermissionGroup", filter, summary_only: true) do |row|
      pgroups << extract_permission_group(row)
    end
    pgroups
  end

  def permission_group(id : Int64 | String)
    # we only want summaries of these, so no prop_param provided
    document = check get("/v2/User/PermissionGroup/#{id}")
    extract_site(document)
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
    "ID"                     => id : Int64,
    "Name"                   => name : String,
    "SiteID"                 => site_id : Int32,
    "SiteName"               => site_name : String,
    "Address"                => address : String,
    "attr_PartitionID"       => partition_id : Int32,
    "cf_origo"               => origo : Bool,
    "cf_phone"               => phone : String,
    "cf_email"               => email : String,
    "PrimaryPermissionGroup" => primary_permission_group : PermissionGroup,
  })

  # users in a site
  def users(site_id : Int32? = nil, email : String? = nil)
    users = [] of User
    filter = Filter{
      "SiteID" => site_id,
      cf_email => email,
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

  def user_id_lookup(email : String) : Array(String)
    users(email: email).map(&.address.as(String))
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def create_user(name : String, email : String, phone : String?) : String
    first_name, second_name = name.split(' ', 2)
    user = extract_add_or_update_result(add_entry("User", UpdateFields{
      "FirstName"  => first_name,
      "SecondName" => second_name,
      cf_email     => email.strip.downcase,
      cf_phone     => phone,
    }.compact!))
    user.address.as(String)
  end

  # ================
  # User Permissions
  # ================

  define_xml_type(UserPermission, {
    "ID" => id : String,
    # returns PartitionID="0" Address="QG4"
    "What"                     => group : PermissionGroup,
    "ManagedByActiveDirectory" => externally_managed : Bool,
    # returns PartitionID="0" Address="U20"
    "User" => user : User,

    "Deny"    => deny : Bool,
    "Expired" => expired : Bool,
  })

  def user_permissions(user_id : String? = nil, group_id : String? = nil, externally_managed : Bool? = nil) : Array(UserPermission)
    user_permissions = [] of UserPermission
    filter = Filter{
      "User.Address"             => user_id,
      "What.Address"             => group_id,
      "ManagedByActiveDirectory" => externally_managed,
    }
    paginate_request("User", "UserPermission", filter) do |row|
      user_permissions << extract_user_permission(row)
    end
    user_permissions
  end

  def managed_users_in_group(group_address : String) : Hash(String, String)
    user_ids = user_permissions(group_id: group_address, externally_managed: true).map do |permission|
      permission.user.address.as(String)
    end

    field = cf_email
    email_user_id = Hash(String, String).new("", users.size)

    user_ids.each do |user_id|
      document = check get("/v2/BasicStatus/User/#{user_id}?AdditionalProperties=#{field}")
      if email = extract_user(document).email
        email_user_id[email.downcase] = user_id
      end
    end

    email_user_id
  end

  @[PlaceOS::Driver::Security(Level::Support)]
  def modify_user_permissions(user_id : String, group_id : String, partition_id : String | Int32? = nil, add : Bool = true, externally_managed : Bool = true)
    payload = XML.build_fragment(indent: "  ") do |xml|
      xml.element("UserPermission") do
        xml.element("What") do
          Ref.new("PermissionGroup", group_id, partition_id).to_xml(xml)
        end

        if add && externally_managed
          xml.element("ManagedByActiveDirectory") { xml.text "True" }
        end
      end
    end

    modify_collection("User", user_id, "Permissions", payload, add: add)
  end

  # sets or unsets the Permission Group
  @[PlaceOS::Driver::Security(Level::Support)]
  def set_user_primary_permission_group(user_id : String, permission_group_id : String?)
    if permission_group_id
      update_entry("User", user_id, UpdateFields{
        "PrimaryPermissionGroup" => Ref.new("PermissionGroup", permission_group_id),
      })
    else
      update_entry("User", user_id, UpdateFields{
        "PrimaryPermissionGroup" => nil,
      })
    end
  end

  # =====
  # Cards
  # =====

  define_xml_type(Card, {
    "ID"                => id : String,
    "Name"              => name : String,
    "CardNumberNumeric" => card_number_numeric : Int64,
    "CardNumber"        => card_number : String,
    "CardSerialNumber"  => card_serial_number : String,
    "IssueNumber"       => issue_number : Int32,
    # Active, ActiveExpiring, ActiveReplacement seem to be the only active states
    "State"             => state : String,
    "ExpiryDateTime"    => expiry : String,
    "StartDateTime"     => valid_from : String,
    "LastUsed"          => last_used : String,
    "CloudCredentialId" => cloud_credential_id : String,
    # None or HIDMobileCredential
    "CloudCredentialType"                 => cloud_credential_type : String,
    "CloudCredentialPoolId"               => cloud_credential_pool_id : String,
    "CloudCredentialInvitationId"         => cloud_credential_invite_id : String,
    "CloudCredentialInvitationCode"       => cloud_credential_invite_code : String,
    "CloudCredentialCommunicationHandler" => cloud_credential_comms_handler : String,
    "ManagedByActiveDirectory"            => active_directory : Bool,
    # these are Ref types so won't be fully hydrated (id and name only)
    "Site" => site : Site,
    "User" => user : User,
  })

  def cards(site_id : Int32? = nil, user_id : String | Int64? = nil)
    cards = [] of Card
    case user_id
    when String
      filter = Filter{
        "Site.ID"      => site_id,
        "User.Address" => user_id,
      }
    else
      filter = Filter{
        "Site.ID" => site_id,
        "User.ID" => user_id,
      }
    end
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
      Door.new(door.id.to_s, door.name)
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
