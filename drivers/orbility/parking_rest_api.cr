require "placeos-driver"
require "./parking_rest_api_models"

# https://apim-dev-hub.developer.azure-api.net/api-details

class Orbility::ParkingRestAPI < PlaceOS::Driver
  descriptive_name "Orbility Parking API"
  generic_name :Orbility
  uri_base "https://api.orbility.com/"

  default_settings({
    api_key:  "854b66cb40",
    login:    "API",
    password: "12345",
  })

  @login : String = ""
  @password : String = ""

  def on_update
    @login = setting?(String, :login) || ""
    @password = setting?(String, :password) || ""

    api_key = setting?(String, :api_key) || ""
    transport.before_request do |request|
      logger.debug { "requesting: #{request.method} #{request.path}?#{request.query}\n#{request.body}" }
      request.headers["Ocp-Apim-Subscription-Key"] = api_key
    end
  end

  macro check(response, klass)
    %response = {{ response }}
    raise "error: #{%response.status}\n#{%response.body}" unless %response.success?
    %klass = {{klass}}.from_json(%response.body)
    raise "error: #{%klass.to_pretty_json}" unless %klass.success?
    %klass
  end

  macro basic_check(response)
    %response = {{ response }}
    raise "error: #{%response.status}\n#{%response.body}" unless %response.success?
    %klass = Confirmation.from_json(%response.body)
    if !%klass.success?
      logger.info { "basic request failed with: #{%klass.to_pretty_json}" }
    end
    %klass.success?
  end

  ##############################
  # Subscriber Interface
  ##############################

  @auth_lock : Mutex = Mutex.new
  @subscriber_auth : AuthResponse? = nil

  protected def subscriber_auth : HTTP::Headers
    @auth_lock.synchronize do
      if token = @subscriber_auth
        return HTTP::Headers{
          "Authorization" => "Bearer #{token.user_token}",
        } unless token.expired?
      end

      @subscriber_auth = nil
      response = post("/subscriberinterface/api/Connection/Connect", body: Auth.new(@login, @password).to_json)
      auth = check(response, AuthResponse)
      auth.expires # called just to set the expiry time
      @subscriber_auth = auth

      # We need to do this as we get an error if we use the bearer token too soon! (WTF)
      sleep 3.seconds

      HTTP::Headers{
        "Authorization" => "Bearer #{auth.user_token}",
      }
    end
  end

  def products : Array(Product)
    response = get("/subscriberinterface/api/Product/GetProducts/", headers: subscriber_auth)
    check(response, Products).products
  end

  def offers(product_id : Int64) : Array(Offer)
    response = get("/subscriberinterface/api/Offer/GetOffersByProduct/#{product_id}", headers: subscriber_auth)
    check(response, Offers).offers
  end

  # no way to list contracts, must know the ID
  def contract(contract_id : Int64) : Contract
    response = get("/subscriberinterface/api/Contract/Get/#{contract_id}", headers: subscriber_auth)
    check(response, Contract)
  end

  def subscriptions(contract_id : Int64) : Array(Subscription)
    response = get("/subscriberinterface/api/Subscription/GetSubscriptionsFromContract/#{contract_id}", headers: subscriber_auth)
    check(response, MultiSubscriptions).subscriptions
  end

  def subscription(subscription_id : Int64) : Subscription
    response = get("/subscriberinterface/api/Subscription/Get/#{subscription_id}", headers: subscriber_auth)
    check(response, SingleSubscription).subscription
  end

  # you can only delete expired subscriptions
  def delete_subscription(subscription_id : Int64) : Bool
    sub = subscription(subscription_id)
    if sub.valid?
      sub.end_date = 2.days.ago
      # in case they ever fix this bug we default to send product id
      sub.send_product_id = sub.send_product_id || sub.receive_product_id
      sub.receive_product_id = nil
      update_subscription(sub)
    end
    response = delete("/subscriberinterface/api/Subscription/Delete/#{subscription_id}", headers: subscriber_auth)
    basic_check(response)
  end

  def add_subscription(subscription : Subscription) : Bool
    response = post("/subscriberinterface/api/Subscription/Add", headers: subscriber_auth, body: subscription.to_json)
    basic_check(response)
  end

  def update_subscription(subscription : Subscription) : Bool
    response = put("/subscriberinterface/api/Subscription/Update", headers: subscriber_auth, body: subscription.to_json)
    basic_check(response)
  end

  def card(card_id : Int64) : Card
    response = get("/subscriberinterface/api/Card/Get/#{card_id}", headers: subscriber_auth)
    check(response, Card)
  end

  def delete_card(card_id : Int64) : Bool
    response = delete("/subscriberinterface/api/Card/Delete/#{card_id}", headers: subscriber_auth)
    basic_check(response)
  end

  def add_card(card : CardUpdate) : Bool
    response = post("/subscriberinterface/api/Card/Add", headers: subscriber_auth, body: card.to_json)
    basic_check(response)
  end

  def update_card(card : CardUpdate) : Bool
    response = put("/subscriberinterface/api/Card/Update", headers: subscriber_auth, body: card.to_json)
    basic_check(response)
  end

  ##############################
  # PreBookings
  ##############################

  @prebooking_auth : AuthResponse? = nil

  protected def prebooking_auth : HTTP::Headers
    @auth_lock.synchronize do
      if token = @prebooking_auth
        return HTTP::Headers{
          "Authorization" => "Bearer #{token.user_token}",
        } unless token.expired?
      end

      @prebooking_auth = nil
      response = post("/prebooking/api/Connection/Connect", body: Auth.new(@login, @password).to_json)
      auth = check(response, AuthResponse)
      auth.expires # called just to set the expiry time
      @prebooking_auth = auth

      # We need to do this as we get an error if we use the bearer token too soon! (WTF)
      sleep 3.seconds

      HTTP::Headers{
        "Authorization" => "Bearer #{auth.user_token}",
      }
    end
  end
end
