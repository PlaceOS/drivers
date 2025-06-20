require "placeos-driver"
require "./sscv2_models"

class Sennheiser::SSCv2Driver < PlaceOS::Driver
  descriptive_name "Sennheiser Sound Control Protocol v2"
  generic_name :AudioDevice
  description "Driver for Sennheiser devices supporting SSCv2 protocol. Requires third-party access to be enabled in Sennheiser Control Cockpit with configured password. Automatically subscribes to /api/device/status and /api/device/info when running_specs is false or nil."

  uri_base "https://device_ip"

  default_settings({
    basic_auth: {
      username: "api",
      password: "configured_password",
    },
    running_specs:          true,
    subscription_resources: [
      "/api/device/site",
    ] of String,
    # Note: /api/device/status and /api/device/info are automatically
    # subscribed when running_specs is false or nil
  })

  @username : String = "api"
  @password : String = ""
  @subscription_resources : Array(String) = [] of String
  @running_specs : Bool = true
  @subscription_processor : Sennheiser::SSCv2::SubscriptionProcessor?

  def on_load
    on_update
  end

  def on_update
    # Extract basic auth credentials
    if basic_auth = setting?(Hash(String, String), :basic_auth)
      @username = basic_auth["username"]? || "api"
      @password = basic_auth["password"]? || ""
    else
      @username = "api"
      @password = ""
    end

    @subscription_resources = setting?(Array(String), :subscription_resources) || [] of String
    running_specs_setting = setting?(Bool, :running_specs)
    @running_specs = running_specs_setting.nil? ? false : running_specs_setting

    # Stop existing subscription processor
    @subscription_processor.try(&.stop)
    @subscription_processor = nil

    # Don't start SSE subscriptions during specs
    return if @running_specs

    # Add default subscriptions
    default_resources = ["/api/device/status", "/api/device/info"]
    default_resources.each do |resource|
      @subscription_resources << resource unless @subscription_resources.includes?(resource)
    end

    # Initialize subscription processor
    base_url = config.uri.not_nil!.to_s.rchop("/")
    processor = Sennheiser::SSCv2::SubscriptionProcessor.new(base_url, @username, @password)

    # Set up callbacks
    processor.on_data do |resource_path, data|
      handle_subscription_data(resource_path, data)
    end

    processor.on_error do |error|
      logger.warn { "SSE subscription error: #{error}" }
    end

    @subscription_processor = processor
  end

  def connected
    return if @running_specs

    # Start SSE subscription
    spawn { start_subscription }
  end

  def disconnected
    @subscription_processor.try(&.stop)
  end

  # === API Methods ===

  def device_info
    get("/api/device/info")
  end

  def device_site
    get("/api/device/site")
  end

  def device_status
    get("/api/device/status")
  end

  def ssc_version
    get("/api/ssc/version")
  end

  def set_device_name(name : String)
    put("/api/device/site", body: {name: name}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def set_device_location(location : String)
    put("/api/device/site", body: {location: location}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def set_device_site(site : String)
    put("/api/device/site", body: {site: site}.to_json, headers: {"Content-Type" => "application/json"})
  end

  # === Subscription Management ===

  def subscribe_to_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.subscribe_to_resources(resources))
  end

  def add_subscription_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.add_resources(resources))
  end

  def remove_subscription_resources(resources : Array(String))
    return if @running_specs
    @subscription_processor.try(&.remove_resources(resources))
  end

  def get_subscription_status
    processor = @subscription_processor

    if processor
      {
        "session_uuid"         => processor.session_uuid || "",
        "subscribed_resources" => processor.subscribed_resources,
        "running"              => processor.running,
      }
    else
      {
        "session_uuid"         => "",
        "subscribed_resources" => [] of String,
        "running"              => false,
      }
    end
  end

  # === Private Methods ===

  private def start_subscription
    processor = @subscription_processor
    return unless processor

    processor.start

    # Wait a moment for connection to establish, then subscribe to default resources
    sleep 2.seconds
    if !@subscription_resources.empty?
      processor.subscribe_to_resources(@subscription_resources)
    end
  end

  private def handle_subscription_data(resource_path : String, data : JSON::Any)
    logger.debug { "Received SSE data for #{resource_path}: #{data}" }

    # Update driver state based on resource path
    case resource_path
    when "/api/device/site"
      begin
        site_data = Sennheiser::SSCv2::DeviceSite.from_json(data.to_json)
        self[:device_name] = site_data.name
        self[:device_location] = site_data.location
        self[:device_site] = site_data.site
      rescue JSON::ParseException
        logger.warn { "Failed to parse device site data: #{data}" }
      end
    when "/api/device/info"
      self[:device_info] = data.as_h
    when "/api/device/status"
      self[:device_status] = data.as_h
    else
      # Store generic resource data
      resource_key = resource_path.gsub("/", "_").gsub(/^_/, "")
      self[resource_key] = data.as_h
    end
  end
end
