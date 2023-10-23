require "placeos-driver"
require "./models/**"

class Delta::API < PlaceOS::Driver
  descriptive_name "Delta API Gateway"
  generic_name :Delta
  uri_base "https://example.delta.io"

  default_settings({
    username:   "admin",
    password:   "admin",
    user_agent: "PlaceOS",
    debug: false
  })

  def on_load
    on_update
  end

  @username : String = "admin"
  @password : String = "admin"
  @user_agent : String = "PlaceOS"
  @debug : Bool = false

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)

    @user_agent = setting?(String, :user_agent) || "PlaceOS"
    @debug = setting?(Bool, :debug) || false
  end

  private def fetch(path : String)
    response = get("#{path}?alt=json", headers: HTTP::Headers{
      "Authorization" => ["Basic", Base64.strict_encode("#{@username}:#{@password}")].join(" "),
      "User-Agent"    => @user_agent,
    })

    logger.debug { response.headers } if @debug
    logger.debug { response.body } if @debug

    response
  end

  # list all sites
  def list_sites
    response = Models::ListSitesResponse.from_json(fetch("/api/.bacnet").body)
    response.json_unmapped.keys
  end

  # list devices for site
  def list_devices_by_site_name(site_name : String)
    devices = [] of Models::Device
    path = URI.encode_path("/api/.bacnet/#{site_name}")

    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    body = Models::ListDevicesBySiteNameResponse.from_json(response.body)

    body.json_unmapped.keys.each do |key|
      value = body.json_unmapped[key].as_h

      devices.push(Models::Device.new(id: key, base: value["$base"].to_s, node_type: value["nodeType"].to_s, display_name: value["displayName"].to_s, truncated: Bool.new(JSON::PullParser.new(value["truncated"].to_s))))
    end

    devices
  end

  # list objects from device resource
  def list_objects_by_device_number(site_name : String, device_number : String)
    objects = [] of Models::Object
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}")
    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    body = Models::ListObjectsByDeviceNumber.from_json(response.body)

    body.json_unmapped.keys.each do |key|
      value = body.json_unmapped[key].as_h

      objects.push(Models::Object.new(id: key, base: value["$base"].to_s, display_name: value["displayName"].to_s, truncated: Bool.new(JSON::PullParser.new(value["truncated"].to_s))))
    end

    objects
  end

  # get value of property from object through instance
  def get_value_property_by_object_type_through_instance(site_name : String, device_number : String, object_type : String, instance : String)
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}/#{object_type},#{instance}")

    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    Models::ValueProperty.from_json(response.body)
  end

  # get value of property from object through property name
  def get_value_property_by_object_type_through_property_name(site_name : String, device_number : String, object_type : String, property_name : String)
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}/#{object_type},#{property_name}")
    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    Models::ValueProperty.from_json(response.body)
  end

  # get value of property from object through subproperty path
  def get_value_property_by_object_type_through_subproperty_path(site_name : String, device_number : String, object_type : String, subproperty_path : String)
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}/#{object_type},#{subproperty_path}")
    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    Models::ValueProperty.from_json(response.body)
  end
end
