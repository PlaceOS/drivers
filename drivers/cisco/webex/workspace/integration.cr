require "json"

module WebxWorkspace
  record XapiAccessKeys, commands : Array(String)?, statuses : Array(String)?, events : Array(String)? do
    include JSON::Serializable
  end

  record CustomerDetails, id : String, name : String? do
    include JSON::Serializable
  end

  struct Queue
    include JSON::Serializable

    getter state : QueueState

    @[JSON::Field(key: "pollUrl")]
    getter poll_url : String?

    def initialize(@state, @poll_url = nil)
    end

    def self.enabled
      new(QueueState::Enabled)
    end
  end

  enum QueueState
    Enabled
    Disabled
    Remove
    Uknown
  end

  enum ProvisioningState
    In_Progress
    Error
    Completed
    Uknown
  end

  enum OperationalState
    Operational
    Impaired
    Outage
    Token_Invalid
    Not_Applicable
    Uknown
  end

  struct Integration
    include JSON::Serializable
    JSON::Serializable::Unmapped

    getter id : String

    @[JSON::Field(key: "manifestVersion")]
    getter manifest_version : Int32

    getter scopes : Array(String)
    getter roles : Array(String)

    @[JSON::Field(key: "xapiAccessKeys")]
    getter xapi_access_keys : XapiAccessKeys?

    @[JSON::Field(key: "createdAt")]
    getter created_at : Time

    @[JSON::Field(key: "updatedAt")]
    getter updated_at : Time

    @[JSON::Field(key: "provisioningState")]
    getter provisioning_state : ProvisioningState

    @[JSON::Field(key: "actionsUrl")]
    getter action_url : String?

    @[JSON::Field(key: "operationalState")]
    getter operational_state : OperationalState?

    getter customer : CustomerDetails?
    getter queue : Queue?
  end

  struct IntegrationUpdate
    include JSON::Serializable

    @[JSON::Field(key: "actionsUrl")]
    getter action_url : String?

    @[JSON::Field(key: "provisioningState")]
    getter provisioning_state : ProvisioningState?
    getter customer : CustomerDetails?
    getter queue : Queue?

    def initialize(@provisioning_state, @queue, @action_url = nil, @customer = nil)
    end
  end
end
