require "http"
require "placeos-driver"
require "./security_interop_models"

class Rhombus::SecurityInterop < PlaceOS::Driver
  descriptive_name "Rhombus Security Interop"
  generic_name :RhombusSecurity
  description %(provides an interface for rhombus and local security platforms)

  default_settings({
    debug_webhook: false,
  })

  @debug_webhook : Bool = false
  @subscriptions : Array(Subscription) = [] of Subscription

  def on_load
    monitor("security/event/door") { |_subscription, payload| door_event(payload) }
    on_update
  end

  def on_update
    @subscriptions = setting?(Array(Subscription), :subscriptions) || [] of Subscription
    @debug_webhook = setting?(Bool, :debug_webhook) || false
  end

  protected def security
    system.implementing(Interface::DoorSecurity)
  end

  def request(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_webhook

    case method.downcase
    when "post"
      # new subscription
      @subscriptions << Subscription.from_json(body)
      define_setting(:subscriptions, @subscriptions)
      {HTTP::Status::CREATED.to_i, {} of String => String, ""}
    when "delete"
      # delete subscription
      sub_webhook = Subscription.from_json(body).webhook
      @subscriptions.reject! { |sub| sub.webhook == sub_webhook }
      define_setting(:subscriptions, @subscriptions)
      {HTTP::Status::ACCEPTED.to_i, {} of String => String, ""}
    when "get"
      # return the list of doors
      all_doors = [] of JSON::Any
      security.door_list.get.each do |doors|
        all_doors.concat doors.as_a
      end
      {HTTP::Status::OK.to_i, {"Content-Type" => "application/json"}, {
        doors: all_doors,
      }.to_json}
    when "put"
      # unlock a door
      door = Interface::DoorSecurity::Door.from_json(body).door_id
      case security.unlock(door).get.first.as_bool?
      in true
        {HTTP::Status::OK.to_i, {} of String => String, ""}
      in false
        {HTTP::Status::FORBIDDEN.to_i, {} of String => String, ""}
      in nil
        {HTTP::Status::NOT_IMPLEMENTED.to_i, {} of String => String, ""}
      end
    else
      {HTTP::Status::BAD_REQUEST.to_i, {"Content-Type" => "application/json"}, {error: "unexpected HTTP request method: #{method}"}.to_json}
    end
  rescue error
    logger.warn(exception: error) { "processing webhook request" }
    {HTTP::Status::INTERNAL_SERVER_ERROR.to_i, {"Content-Type" => "application/json"}, error.message.to_s}
  end

  @[Security(Level::Administrator)]
  def door_event(json : String)
    @subscriptions.each do |sub|
      webhook = Webhook.new Interface::DoorSecurity::DoorEvent.from_json(json)
      if secret = sub.secret
        webhook.sign(secret)
      end
      response = HTTP::Client.post(
        sub.webhook,
        HTTP::Headers{"Content-Type" => "application/json"},
        webhook.to_json
      )
      logger.warn { "request #{sub.webhook} failed with status: #{response.status_code}\n#{response.body}" } unless response.success?
    end
  end
end
