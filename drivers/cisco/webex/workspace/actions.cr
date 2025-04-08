require "json"
require "./integration"
require "connect-proxy"

module WebxWorkspace
  abstract struct Action
    include JSON::Serializable

    @[JSON::Field(key: "sub")]
    getter org_id : String

    @[JSON::Field(key: "appId")]
    getter app_id : String

    getter action : String

    use_json_discriminator "action", {"updateApproved": UpdateApproved, "deprovision": Deprovisioning, "healthCheck": HealthCheckRequest,
                                      "provision": Provisioning, "update": Updated}

    def initialize(@app_id, @org_id, @action)
    end
  end

  struct Deprovisioning < Action
    def initialize(@app_id, @org_id, @action)
      super
    end
  end

  struct HealthCheckRequest < Action
    def initialize(@app_id, @org_id, @action)
      super
    end
  end

  struct Updated < Action
    @[JSON::Field(key: "manifestVersion")]
    getter manifest_version : String

    def initialize(@app_id, @org_id, @action, @manifest_version)
      super
    end
  end

  struct UpdateApproved < Action
    @[JSON::Field(key: "refreshToken")]
    getter refresh_token : String

    def initialize(@app_id, @org_id, @action, @refresh_token)
      super
    end
  end

  struct Provisioning < Action
    @[JSON::Field(key: "oauthUrl")]
    getter oauth_url : String

    @[JSON::Field(key: "orgName")]
    getter org_name : String

    @[JSON::Field(key: "appUrl")]
    getter app_url : String

    @[JSON::Field(key: "userId")]
    getter user_id : String

    @[JSON::Field(key: "manifestUrl")]
    getter manifest_url : String

    @[JSON::Field(key: "expiryTime")]
    getter expiry_time : Time

    @[JSON::Field(key: "webexapisBaseUrl")]
    getter webexapis_base_url : String

    getter scopes : String
    getter region : String

    @[JSON::Field(key: "iat", converter: Time::EpochConverter)]
    getter issued_at : Time

    getter jti : String

    @[JSON::Field(key: "refreshToken")]
    getter refresh_token : String

    @[JSON::Field(key: "xapiAccess")]
    getter xapi_access : XapiAccessKeys

    def initialize(@app_id, @org_id, @action, @oauth_url, @action_url, @org_name, @app_url, @user_id, @manifest_url, @expiry_time, @webexapis_base_url,
                   @scopes, @region, @issued_at, @jti, @refresh_token, @xapi_access)
      super(@app_id, @org_id)
    end

    def oauth_uri : URI
      URI.parse(oauth_url)
    end

    def app_uri : URI
      URI.parse(app_url)
    end

    def refresh_token=(new_token) : Nil
      @refresh_token = new_token unless @refresh_token == new_token
    end
  end
end
