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
    api_key: "api-access-key",
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
  end

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
    %hash = {} of Symbol => String

    if %data = {{document}}.first_element_child
      %data.children.select(&.element?).each do |child|
        case child.name
        {% for variable, node in keys %}
        when {{node.id.stringify}}
          %hash[{{variable.id.symbolize}}] = child.content || ""
        {% end %}
        end
      end
    end

    %hash
  end

  # <ApiVersion>http://20.213.104.2:80/restapi/ApiVersion/v2</ApiVersion>
  def api_version : String
    document = check get("/ApiVersion")
    uri = URI.parse document.first_element_child.try(&.content).as(String)
    Path[uri.path].basename
  end

  # <ProductEdition>Integriti Professional Edition</ProductEdition>
  # <ProductVersion>23.1.1.21454</ProductVersion>
  # <ProtocolVersion>3</ProtocolVersion>
  def system_info
    document = check get("/v2/SystemInfo")
    details = extract(document, {
      edition:  "ProductEdition",
      version:  "ProductVersion",
      protocol: "ProtocolVersion",
    })
    details
  end

  # =======================
  # Door Security Interface
  # =======================

  def door_list : Array(Door)
    # doors.map { |d| Door.new(d.id, d.name) }
    raise "not implemented"
    [] of Door
  end

  def unlock(door_id : String) : Bool?
    # response = post("#{@doors_endpoint}/#{door_id}/open", headers: @headers)
    # response.success?
    raise "not implemented"
    true
  end
end
