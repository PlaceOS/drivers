require "json"
require "connect-proxy"
require "./jws"
require "./integration"
require "./queue_poller"
require "../cloud_xapi/models"

module WebxWorkspace
  alias ProxyConfig = NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?)

  def self.new_client(url : URI, proxy_config : ProxyConfig? = nil)
    client = ConnectProxy::HTTPClient.new(url)
    return client unless proxy_config
    if proxy_conf = proxy_config
      if proxy_conf[:host].presence
        proxy = ConnectProxy.new(**proxy_conf)
        client.before_request { client.set_proxy(proxy) }
      end
    elsif ConnectProxy.behind_proxy?
      begin
        proxy = ConnectProxy.new(*ConnectProxy.parse_proxy_url)
        client.before_request { client.set_proxy(proxy) }
      rescue error
      end
    end
    client
  end

  class WorkspaceIntegration
    getter client_id : String
    getter client_secret : String
    getter jwt_decoder : JWTDecoder
    getter! queue_url : String

    getter! provisioning : Provisioning
    getter! oauth_tokens : CloudXAPI::Models::DeviceToken
    getter! poller : QueuePoller
    getter! proxy_config : ProxyConfig

    def initialize(@client_id, @client_secret, @proxy_config = nil)
      @jwt_decoder = JWTDecoder.new(@proxy_config)
    end

    def initialized? : Bool
      !!(oauth_tokens?)
    end

    def update_auth_tokens(updated : CloudXAPI::Models::DeviceToken)
      if oauth_tokens?.nil?
        @oauth_tokens = updated
        return
      end

      @oauth_tokens = updated if updated.refresh_expiry > oauth_tokens.refresh_expiry || updated.expiry > oauth_tokens.expiry
    end

    def queue_url=(url : String)
      @queue_url = url unless @queue_url == url
    end

    def init_with_queue(activation_jwt : String)
      update = IntegrationUpdate.new(ProvisioningState::Completed, Queue.enabled)
      init(activation_jwt, update)
    end

    def init(activation_jwt : String, initial_update : IntegrationUpdate)
      @provisioning = jwt_decoder.decode_action(activation_jwt).as(Provisioning)
      init_tokens
      post_update(initial_update)
      oauth_tokens
    end

    def init_tokens
      if provisioning?
        refresh_token = provisioning.refresh_token
        oauth_uri = provisioning.oauth_uri
      elsif oauth_tokens?
        refresh_token = oauth_tokens.refresh_token
        oauth_uri = URI.parse("https://webexapis.com/v1/access_token")
      else
        raise "Invalid state: neither provisioning nor auth tokens are valid."
      end

      body = URI::Params.build do |form|
        form.add("grant_type", "refresh_token")
        form.add("client_id", client_id)
        form.add("client_secret", client_secret)
        form.add("refresh_token", refresh_token)
      end

      headers = HTTP::Headers{
        "Content-Type" => "application/x-www-form-urlencoded",
        "Accept"       => "application/json",
      }

      client = WebxWorkspace.new_client(oauth_uri, @proxy_config)
      response = client.post(oauth_uri.request_target, headers: headers, body: body)
      raise "failed to refresh access token for client-id #{client_id}, code #{response.status_code}, body #{response.body}" unless response.success?

      @oauth_tokens = CloudXAPI::Models::DeviceToken.from_json(response.body)
      provisioning.refresh_token = oauth_tokens.refresh_token if provisioning?
      oauth_tokens
    end

    def queue_poller(&block : Array(Message) ->)
      return poller if poller?
      raise "The queue url has not been initialized. Make sure to init with an update that enables a queue" unless queue_url?
      @poller = QueuePoller.new(URI.parse(queue_url), jwt_decoder, @proxy_config, ->headers, block)
      poller
    end

    def headers : HTTP::Headers
      HTTP::Headers{
        "Authorization" => oauth_tokens.auth_token,
        "Content-Type"  => "application/json",
        "Accept"        => "application/json",
      }
    end

    def keep_token_refreshed
      return nil unless oauth_tokens?
      init_tokens if 1.minute.from_now < oauth_tokens.expiry || 1.minute.from_now < oauth_tokens.refresh_expiry
    end

    private def post_update(update : IntegrationUpdate)
      client = WebxWorkspace.new_client(provisioning.app_uri, @proxy_config)
      response = client.patch(provisioning.app_uri.request_target, headers: headers, body: update.to_json)
      raise "failed to patch integration endpoint, code #{response.status_code}, body #{response.body}" unless response.success?

      integration = Integration.from_json(response.body)
      @queue_url = integration.queue.try &.poll_url
      integration
    end
  end
end
