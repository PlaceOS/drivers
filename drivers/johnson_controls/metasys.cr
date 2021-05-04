require "inactive-support/macro/args"

class JohnsonControls::Metasys < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Johnson Controls Metasys API v3"
  generic_name :Control
  uri_base "http://localhost/api/v3"

  CONTENT_TYPE = "application/json"
  ISO8601 = Time::Format.new("%FT%TZ")

  @username : String = ""
  @password : String = ""
  @auth_token : String = ""
  @auth_expiry : Time = 1.minute.ago

  def on_load
    on_update
  end

  def on_update
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
  end

  def token_expired?
    @auth_expiry <= Time.utc
  end

  class AuthResponse
    include JSON::Serializable

    @[JSON::Field(key: "accessToken")]
    property access_token : String

    @[JSON::Field(converter: JohnsonControls::Metasys::ISO8601)]
    property expires : Time
  end

  def get_token
    return @auth_token unless token_expired?

    response = post("/login",
      headers: {"Content-Type" => CONTENT_TYPE},
      body: {
        username: @username,
        password: @password
      }.to_json
    )

    data = response.body.not_nil!
    logger.debug { "received login response #{data}" }

    if response.success?
      resp = AuthResponse.from_json(data)
      @auth_expiry = resp.expires
      @auth_token = "Bearer #{resp.access_token}"
    else
      logger.error { "authentication failed with HTTP #{response.status_code}" }
      raise "failed to obtain access token"
    end
  end

  enum Type
    Blah

    def to_s
      value.to_s
    end
  end

  enum Attribute
    Blah

    def to_s
      value.to_s
    end
  end

  enum Category
    Blah

    def to_s
      value.to_s
    end
  end

  def get_alarms(
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    priority_from : Int64? = nil,
    priority_to : Int64? = nil,
    type : Type? = nil,
    exclude_pending : Bool = false,
    exclude_acknowledged : Bool = false,
    exclude_discarded : Bool = false,
    attribute : Attribute? = nil,
    category : Category? = nil,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "creationTime"
  )
    response = get_request("/alarms", **args)
  end

  def get_alarm(id : String)
    response = get_request("/alarms/#{id}")
  end

  def get_alarms_for_network_device(
    id : String,
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    priority_from : Int64? = nil,
    priority_to : Int64? = nil,
    type : Type? = nil,
    exclude_pending : Bool = false,
    exclude_acknowledged : Bool = false,
    exclude_discarded : Bool = false,
    attribute : Attribute? = nil,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "creationTime"
  )
    response = get_request("/networkDevices/#{id}/alarms", **args)
  end

  def get_alarms_for_object(
    id : String,
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    priority_from : Int64? = nil,
    priority_to : Int64? = nil,
    type : Type? = nil,
    exclude_pending : Bool = false,
    exclude_acknowledged : Bool = false,
    exclude_discarded : Bool = false,
    attribute : Attribute? = nil,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "creationTime"
  )
    response = get_request("/objects/#{id}/alarms", **args)
  end

  def get_alarm_annotations(
    id : String,
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "creationTime"
  )
    response = get_request("/alarms/#{id}/annotations", **args)
  end

  def get_audit_annotations(
    id : String,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "-creationTime"
  )
    response = get_request("/alarms/#{id}/annotations", **args)
  end

  def get_audits(
    origin_applications : String? = nil,
    classes_levels : String? = nil,
    action_types : String? = nil,
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    exclude_discarded : Bool = false,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "-creationTime"
  )
    response = get_request("/audits", **args)
  end

  def get_audit(id : String)
    response = get_request("/audits/#{id}")
  end

  def get_audits_for_object(
    id : String,
    origin_applications : String? = nil,
    classes_levels : String? = nil,
    action_types : String? = nil,
    start_epoch : Int64? = nil,
    end_epoch : Int64? = nil,
    exclude_discarded : Bool = false,
    page : Int32 = 1,
    page_size : Int32 = 100,
    sort : String = "-creationTime"
  )
    response = get_request("/objects/#{id}/audits", **args)
  end

  @[Security(Level::Support)]
  def get_request(path : String, **params)
    response = if params.size > 0
      get(path, headers: {"Authorization" => get_token}, params: stringify_params(**params))
    else
      get(path, headers: {"Authorization" => get_token})
    end
    parsed_json_body = begin
      JSON.parse(response.body)
    rescue ex : JSON::ParseException
      ex.to_s
    end
    {
      body: response.body,
      parsed_json_body: parsed_json_body,
      status_code: response.status_code
    }
  end

  # Stringify param keys and values so that they're valid query params
  private def stringify_params(**params) : Hash(String, String)
    hash = Hash(String, String).new
    params.each do |k, v|
      next if v.nil? # Remove params with nil values

      # Some of these are a bit hacky but are needed to make the compiler happy
      # like the next lines for start_epoch/end_epoch
      case k
      when :start_epoch
        next unless start_epoch = params[:start_epoch]?
        hash["startTime"] = ISO8601.format(Time.unix(start_epoch))
      when :end_epoch
        next unless end_epoch = params[:end_epoch]?
        hash["endTime"] = ISO8601.format(Time.unix(end_epoch))
      when :priority_from
        hash["priorityRange"] = "#{params[:priority_from]?},#{params[:priority_to]?}"
      when :priority_to # Do nothing as we are already handling this in priority_from
      when :id # Also, do nothing as id will be used in the route and not as a query param
      else
        hash[k.to_s.camelcase(lower: true)] = v.to_s
      end
    end
    hash
  end
end
