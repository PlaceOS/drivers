require "json"

module WebxWorkspace
  record Event, key : String, value : String, timestamp : Time do
    include JSON::Serializable
  end

  record StatusChanges, updated : Hash(String, JSON::Any)?, removed : Array(String)? do
    include JSON::Serializable
  end

  module ChangeStatus
    @[JSON::Field(key: "appId")]
    getter app_id : String

    @[JSON::Field(key: "deviceId")]
    getter device_id : String

    @[JSON::Field(key: "workspaceId")]
    getter workspace_id : String

    @[JSON::Field(key: "orgId")]
    getter org_id : String

    getter timestamp : Time
  end

  abstract struct Message
    include JSON::Serializable

    getter type : String

    use_json_discriminator "type", {"status": StatusMessage, "events": EventsMessage, "healthCheck": HealthCheckMessage, "action": ActionMessage}

    def initialize(@type)
    end
  end

  struct ActionMessage < Message
    getter jwt : String

    def initialize(@jwt, @type)
      super
    end
  end

  struct StatusMessage < Message
    include ChangeStatus

    @[JSON::Field(key: "isFullSync")]
    getter? full_sync : Bool

    getter changes : StatusChanges

    def initialize(@type, @app_id, @device_id, @workspace_id, @org_id, @timestamp, @full_sync, @changes)
      super
    end
  end

  struct EventsMessage < Message
    include ChangeStatus

    getter events : Array(Event)

    def initialize(@type, @app_id, @device_id, @workspace_id, @org_id, @timestamp, @events)
      super
    end
  end

  struct HealthCheckMessage < Message
    @[JSON::Field(key: "orgId")]
    getter org_id : String?

    @[JSON::Field(key: "appId")]
    getter app_id : String?

    getter timestamp : Time

    def initialize(@type, @timestamp, @org_id = nil, @app_id = nil)
      super
    end
  end
end
