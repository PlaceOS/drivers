require "placeos-driver"
require "inactive-support/args"
require "./metasys_models"

class JohnsonControls::Metasys < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Johnson Controls Metasys API v3"
  generic_name :Control
  uri_base "http://localhost/api/v3"

  CONTENT_TYPE = "application/json"

  @username : String = ""
  @password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago
  @equipment_ids_and_attributes = {} of String => Array(String)
  @poll_interval_seconds : Int32 = 300
  @count : Int32 = 0
  @averages = {} of String => Float64

  def on_update
    schedule.clear
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
    @equipment_ids_and_attributes = setting?(Hash(String, Array(String)), :equipment_ids_and_attributes) || {} of String => Array(String)
    @poll_interval_seconds = setting?(Int32, :poll_interval_seconds) || 300
    @count = 0
    schedule.every(@poll_interval_seconds.seconds, true) { update_data }
  end

  def token_expired?
    @auth_expiry <= Time.utc
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/login",
      headers: {"Content-Type" => CONTENT_TYPE},
      body: {
        username: @username,
        password: @password,
      }.to_json
    )

    logger.debug { "received login response #{response.body}" }

    if response.success?
      resp = AuthResponse.from_json(response.body)
      @auth_expiry = resp.expires
      @auth_token = "Bearer #{resp.access_token}"
    else
      logger.error { "authentication failed with HTTP #{response.status_code}" }
      raise "failed to obtain access token"
    end
  end

  def get_token_debug
    response = post("/login",
      headers: {"Content-Type" => CONTENT_TYPE},
      body: {
        username: @username,
        password: @password,
      }.to_json
    )

    if response.success?
      resp = AuthResponse.from_json(response.body)
      @auth_expiry = resp.expires
      @auth_token = "Bearer #{resp.access_token}"
    else
      parsed_json_body = begin
        JSON.parse(response.body)
      rescue ex : JSON::ParseException
        ex.to_s
      end

      {
        body:             response.body,
        parsed_json_body: parsed_json_body,
        status_code:      response.status_code,
      }
    end
  end

  def get_equipment_points(id : String) : EquipmentPoints
    response = get_request("/equipment/#{id}/points")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    EquipmentPoints.from_json(response.body)
  end

  def get_attribute_value(id : String) : Float64
    current_time = Time.utc
    # get a time object twice the poll interval into the past to ensure we can definitely get the latest value
    short_while_ago = Time.utc - (@poll_interval_seconds * 2).seconds
    # 85 is the identifier to get the presentValue of an object
    response = get_request(
      "/objects/#{id}/attributes/85/samples",
      start_time: short_while_ago.to_rfc3339,
      end_time: current_time.to_rfc3339,
      page_size: 1,      # only get 1 result which will be the latest value with help of the sort option below
      sort: "-timestamp" # sort so that latest value shows first
    )
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    SamplesResponse.from_json(response.body).items.first.value.actual
  end

  def lookup_object_id(fqr : String) : String
    response = get_request("/objectIdentifiers?fqr=#{fqr}")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    response.body.to_s
  end

  def get_network_device_children(id : String, page : Int32 = 1, page_size : Int32 = 10) : GetNetworkDeviceChildrenResponse
    response = get_request("/networkDevices/#{id}/objects",
      page: page,
      page_size: page_size,
      sort: "-timestamp" # sort so that latest value shows first
    )
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    GetNetworkDeviceChildrenResponse.from_json(response.body)
  end

  def get_equipment_hosted_by_network_device(id : String, page : Int32 = 1, page_size : Int32 = 10) : GetEquipmentHostedByNetworkDeviceResponse
    response = get_request("/networkDevices/#{id}/equipment",
      page: page,
      page_size: page_size,
      sort: "-timestamp"
    )
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    GetEquipmentHostedByNetworkDeviceResponse.from_json(response.body)
  end

  def get_object_attributes_with_samples(id : String) : GetObjectAttributesWithSamplesResponse
    response = get_request("/objects/#{id}/trendedAttributes")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    GetObjectAttributesWithSamplesResponse.from_json(response.body)
  end

  def get_single_object_presentValue(id : String) : GetSingleObjectPresentValueResponse
    response = get_request("/objects/#{id}/attributes/presentValue")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    GetSingleObjectPresentValueResponse.from_json(response.body)
  end

  def get_samples_for_an_object_attribute(id : String, attribute_id : String, start_time : String, end_time : String, page : Int32 = 1, page_size : Int32 = 10) : GetSamplesForAnObjectAttributeResponse
    response = get_request("/objects/#{id}/attributes/#{attribute_id}/samples",
      start_time: start_time,
      end_time: end_time,
      page: page,
      page_size: page_size,
      sort: "-timestamp"
    )

    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    GetSamplesForAnObjectAttributeResponse.from_json(response.body)
  end

  def get_commands_for_an_object(id : String) : Array(Command)
    response = get_request("/objects/#{id}/commands")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    Array(Command).from_json(response.body)
  end

  def send_command_to_an_object(id : String, command_id : String, body : Array(JSON::Any))
    response = put_request("/objects/#{id}/commands/#{command_id}", body: body)
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
  end

  def update_data
    debug = {} of String => Hash(String, Float64)
    data = {} of String => Hash(String, Float64)
    @equipment_ids_and_attributes.each do |id, attributes|
      equipment_points = get_equipment_points(id)
      equipment_points.points.each do |p|
        next unless attributes.includes?(p.name)
        data[p.equipment_name] ||= {} of String => Float64
        debug[p.equipment_name] ||= {} of String => Float64
        object_id = p.object_url.split('/').last
        value = get_attribute_value(object_id)
        data[p.equipment_name][p.name] = value
        debug[p.equipment_name][p.object_url] = value
      end
    end

    averages = calculate_averages(data)

    {
      data:                         self[:data] = data,
      count:                        @count,
      equipment_ids_and_attributes: @equipment_ids_and_attributes,
      debug:                        debug,
      averages:                     self[:averages] = averages,
    }
  end

  private def calculate_averages(data)
    sums = {} of String => Float64
    no_of_sensors = {} of String => Int32

    data.each do |_sensor_name, values|
      values.each do |attribute_name, attribute_value|
        no_of_sensors[attribute_name] ||= 0
        no_of_sensors[attribute_name] += 1
        sums[attribute_name] ||= 0
        sums[attribute_name] += attribute_value
      end
    end

    sums.each do |attribute_name, attribute_sum|
      # If there are multiple sensors, divide the sum by the number of sensors
      # This will provide the average of each sensor that has this attribute
      sensor_avg = attribute_sum / no_of_sensors[attribute_name]
      @averages[attribute_name] ||= 0
      @averages[attribute_name] = ((@averages[attribute_name] * @count) + sensor_avg) / (@count + 1)
    end

    @count += 1
    @averages
  end

  def get_data
    {
      data:     self[:data],
      averages: self[:averages],
    }
  end

  private def get_request(path : String, **params)
    if params.size > 0
      get(path, headers: {"Authorization" => get_token}, params: stringify_params(**params))
    else
      get(path, headers: {"Authorization" => get_token})
    end
  end

  private def put_request(path : String, body)
    put(path, headers: {"Authorization" => get_token, "Content-Type" => CONTENT_TYPE}, body: body.to_json)
  end

  @[Security(Level::Support)]
  def get_request_debug(path : String, **params)
    response = get_request(path, **params)

    parsed_json_body = begin
      JSON.parse(response.body)
    rescue ex : JSON::ParseException
      ex.to_s
    end

    {
      body:             response.body,
      parsed_json_body: parsed_json_body,
      status_code:      response.status_code,
    }
  end

  def count
    @count
  end

  # Stringify param keys and values so that they're valid query params
  private def stringify_params(**params) : Hash(String, String)
    hash = Hash(String, String).new
    params.each do |k, v|
      next if v.nil? # Ignore params with nil values

      case k
      when :start_epoch
        hash["startTime"] = ISO8601.format(Time.unix(v.to_i64))
      when :end_epoch
        hash["endTime"] = ISO8601.format(Time.unix(v.to_i64))
      when :id # Ignore as id will be used in the route and not as a query param
      else
        hash[k.to_s.camelcase(lower: true)] = v.to_s
      end
    end
    hash
  end
end
