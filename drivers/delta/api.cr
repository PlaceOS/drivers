require "placeos-driver"
require "./models/**"

class Delta::API < PlaceOS::Driver
  descriptive_name "Delta API Gateway"
  generic_name :Delta
  uri_base "https://example.delta.io"

  default_settings({
    basic_auth: {
      username: "srvc_acct",
      password: "password!",
    },
    user_agent: "PlaceOS",
    debug:      false,
  })

  @user_agent : String = "PlaceOS"
  @debug : Bool = false

  def on_update
    @user_agent = setting?(String, :user_agent) || "PlaceOS"
    @debug = setting?(Bool, :debug) || false
  end

  private def fetch(path : String, skip : Int32 = 0, max_results : Int32 = 1000)
    logger.debug { config.uri } if @debug
    request = "#{path}?alt=json&skip=#{skip}&max-results=#{max_results}"
    logger.debug { request } if @debug

    response = get(request, headers: HTTP::Headers{
      "User-Agent" => @user_agent,
      "Accept"     => "*/*",
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
  def list_devices(site_name : String)
    skip = 0
    devices = [] of Models::Device
    path = URI.encode_path("/api/.bacnet/#{site_name}")

    loop do
      response = fetch(path, skip)

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      # returns this when there are no more results
      # {"Collection":""}

      body = Models::ListDevicesBySiteNameResponse.from_json(response.body)
      body.json_unmapped.keys.each do |key|
        value = body.json_unmapped[key].as_h
        devices.push(Models::Device.new(id: key.to_u32, base: value["$base"].to_s, node_type: value["nodeType"].to_s, display_name: value["displayName"].to_s))
      end

      break unless body.next_req.presence
      skip += 1000
    end

    devices
  end

  # list objects from device resource
  def list_device_objects(site_name : String, device_number : String | UInt32)
    skip = 0
    objects = [] of Models::Object
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}")

    loop do
      response = fetch(path, skip)

      raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
      logger.debug { "response body:\n#{response.body}" }

      body = Models::ListObjectsByDeviceNumber.from_json(response.body)
      body.json_unmapped.each do |key, obj|
        value = obj.as_h
        object_type, instance = key.split(',', 2)
        objects.push(Models::Object.new(object_type, instance, base: value["$base"].to_s, display_name: value["displayName"].to_s))
      end

      break unless body.next_req.presence
      skip += 1000
    end

    objects
  end

  # get value of property from object through instance
  def get_object_value(site_name : String, device_number : String | UInt32, object_type : String, instance : String | UInt32)
    path = URI.encode_path("/api/.bacnet/#{site_name}/#{device_number}/#{object_type},#{instance}")

    response = fetch(path)

    raise "unexpected response #{response.status_code}\n#{response.body}" unless response.success?
    logger.debug { "response body:\n#{response.body}" }

    Models::ValueProperty.from_json(response.body)
  end
end
