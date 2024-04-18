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
  end

  getter default_unlock_time : Int32 = 10

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

  macro extract(document, keys)
    {% for node, variable in keys %}
      {% resolved_type = variable.type.resolve %}
      {% if resolved_type == Int32 %}
        var_{{ variable.var }} = 0
      {% elsif resolved_type == Int64 %}
        var_{{ variable.var }} = 0_i64
      {% elsif resolved_type == Float64 %}
        var_{{ variable.var }} = 0.0
      {% else %}
        var_{{ variable.var }} = ""
      {% end %}
    {% end %}

    if %data = {{document}}.document? ? {{document}}.first_element_child : {{document}}
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
          {% elsif resolved_type == Float64 %}
            var_{{ variable.var }} = %content.to_f? || 0.0
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

  # <ApiVersion>http://20.213.104.2:80/restapi/ApiVersion/v2</ApiVersion>
  def api_version : String
    document = check get("/ApiVersion")
    uri = URI.parse document.first_element_child.try(&.content).as(String)
    Path[uri.path].basename
  end

  def system_info
    document = check get("/v2/SystemInfo")
    extract(document, {
      "ProductEdition"  => edition : String,
      "ProductVersion"  => version : String,
      "ProtocolVersion" => protocol : Int32,
    })
  end

  protected def paginate_request(next_page : String, &)
    loop do
      document = check get(next_page)

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

  alias Site = NamedTuple(id: Int64, name: String)

  def sites : Array(Site)
    sites = [] of Site
    paginate_request("/v2/BasicStatus/SiteKeyword?PageSize=1000") do |row|
      sites << extract(row, {
        "ID"   => id : Int64,
        "Name" => name : String,
      })
    end
    sites
  end

  # =======================
  # Door Security Interface
  # =======================

  @[PlaceOS::Driver::Security(Level::Support)]
  def door_list : Array(Door)
    # doors.map { |d| Door.new(d.id, d.name) }
    raise "not implemented"
    [] of Door
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
