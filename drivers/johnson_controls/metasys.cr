require "inactive-support/macro/args"

class JohnsonControls::Metasys < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Johnson Controls Metasys API v2"
  generic_name :Guests
  uri_base "http://localhost/api/v2"

  CONTENT_TYPE = "application/json"
  ISO8601 = Time::Format.new("%FT%T%z")

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

  enum Sort
    ItemReferenceAsc
    PriorityAsc
    CreationTimeAsc
    ItemReferenceDes
    PriorityDes
    CreationTimeDes

    def to_s
      value = super.camelcase(lower: true)
      value = '-' + value if value.ends_with?("Des") # Prepend '-' if we want descending order
      value[0..-4] # Ignore the last 3 characters e.g. Asc or Des
    end
  end

  def get_alarms(
    start_time : Int64? = nil,
    end_time : Int64? = nil,
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
    sort : Sort = Sort::CreationTimeAsc
  )
    params = args_to_params(**args)

    response = get("/alarms",
      headers: {"Authorization" => get_token},
      params: params
    )
  end

  def get_alarm(id : String)
    response = get("/alarms/#{id}",
      headers: {"Authorization" => get_token}
    )
  end

  def get_alarm_for_network_device(
    id : String,
    start_time : Int64? = nil,
    end_time : Int64? = nil,
    priority_from : Int64? = nil,
    priority_to : Int64? = nil,
  )
  end

  # Map method arguments to the correct string key and string values for query params
  private def args_to_params(**params) : Hash(String, String)
    hash = Hash(String, String).new
    params.each do |k, v|
      next if v.nil?

      case k
      when :start_time, :end_time # Convert to an ISO8601 date string
        hash[k.to_s.camelcase(lower: true)] = ISO8601.format(Time.unix(v.as(Int64)))
      when :priority_from
        hash["priorityRange"] = "#{params[:priority_from]},#{params[:priority_to]}"
      when :priority_to # Do nothing as we are already handling this in priority_from
      else
        hash[k.to_s.camelcase(lower: true)] = v.to_s
      end
    end
    hash
  end
end
