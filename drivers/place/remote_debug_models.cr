require "json"

# Models of the RemoteDebug driver. They match the types in
# `libs/common/src/lib/remote-debug.ts` of PlaceOS/user-interfaces.
# See `docs/remote-debug.md` in that repository.
module Place
  # Log levels, lowest first. A request gets the entries at its level and higher
  enum RemoteLogLevel
    Debug
    Info
    Warn
    Error
  end

  enum RemoteLogSource
    Console
    Error
    Rejection
  end

  # Log entry that a device sends with `post_logs`
  struct RemoteLogEntry
    include JSON::Serializable

    # Most characters in a message. The device sends 2,000 maximum
    MAX_MESSAGE = 2000

    # Number of the entry on the device. Starts at 1 when the app loads
    getter seq : Int64
    # Unix epoch in milliseconds on the device clock
    getter timestamp : Int64
    getter level : RemoteLogLevel
    getter source : RemoteLogSource
    getter message : String

    def initialize(@seq, @timestamp, @level, @source, @message)
    end

    def after_initialize
      @message = @message[0, MAX_MESSAGE] if @message.size > MAX_MESSAGE
    end
  end

  # Details of the device that the device sends with each call
  struct RemoteDebugDevice
    include JSON::Serializable

    getter id : String
    # Short name of the app
    getter app : String
    getter version : String
    # Git hash of the build
    getter build : String
    # Page address, without credentials
    getter url : String
    getter user_agent : String
    # Unix epoch in milliseconds when the app loaded. A new value shows that the app reloaded
    getter started_at : Int64

    # Unix epoch in milliseconds of the last call. Only set in the `devices` binding
    @[JSON::Field(ignore_deserialize: true)]
    property last_seen : Int64? = nil

    def initialize(@id, @app, @version, @build, @url, @user_agent, @started_at)
    end
  end

  # Log request in the `device:<id>` binding
  struct RemoteLogRequest
    include JSON::Serializable

    # Unique ID of the request. A device applies each ID one time
    getter id : String
    getter level : RemoteLogLevel
    # Most buffered entries to send first. `0` sends only new entries
    getter history : Int32?
    # Send only buffered entries with a `seq` lower than this value
    getter before : Int64?
    # Milliseconds that the device sends new entries
    getter duration : Int32?

    def initialize(@id, @level, @history = nil, @before = nil, @duration = nil)
    end
  end

  # Options of `request_logs`
  struct RemoteLogRequestOptions
    include JSON::Serializable

    getter history : Int32?
    getter before : Int64?
    getter duration : Int32?

    def initialize(@history = nil, @before = nil, @duration = nil)
    end
  end

  enum RemoteDebugCommandType
    Status
    Settings
    Storage
    Navigate
    Reload
    ClearCache
    Snapshot
    Animation
  end

  enum RemoteDebugMediaFormat
    Webp
    Gif
  end

  # Options of `send_command`. `keys` for `settings`, `path` for `navigate`,
  # `width` for `snapshot`, and all but `keys` and `path` for `animation`
  struct RemoteDebugCommandOptions
    include JSON::Serializable

    getter keys : Array(String)?
    getter path : String?
    getter width : Int32?
    getter duration : Int32?
    getter fps : Int32?
    getter format : RemoteDebugMediaFormat?

    def initialize(@keys = nil, @path = nil, @width = nil, @duration = nil, @fps = nil, @format = nil)
    end
  end

  # Command in the `device:<id>` binding. Fields that the type does not use are not set
  struct RemoteDebugCommand
    include JSON::Serializable

    getter id : String
    getter type : RemoteDebugCommandType
    getter keys : Array(String)?
    getter path : String?
    getter width : Int32?
    getter duration : Int32?
    getter fps : Int32?
    getter format : RemoteDebugMediaFormat?

    def initialize(@id, @type, @keys = nil, @path = nil, @width = nil, @duration = nil, @fps = nil, @format = nil)
    end
  end

  # Value of the `device:<id>` binding. A class, as the driver changes it in place
  class RemoteDebugDeviceState
    include JSON::Serializable

    # Active log request. `null` when there is none
    @[JSON::Field(emit_null: true)]
    property logs : RemoteLogRequest? = nil
    # Commands for the device, oldest first
    property commands : Array(RemoteDebugCommand) = [] of RemoteDebugCommand

    def initialize
    end

    def empty?
      logs.nil? && commands.empty?
    end
  end

  # Result of a command that a device sends with `command_result`
  struct RemoteDebugResult
    include JSON::Serializable

    getter ok : Bool
    getter data : JSON::Any?
    # Reason that the command failed
    getter error : String?

    def initialize(@ok, @data = nil, @error = nil)
    end
  end

  # Item of the `results:<id>` binding
  record RemoteDebugCommandResult,
    id : String,
    type : RemoteDebugCommandType,
    result : RemoteDebugResult,
    received_at : Int64 do
    include JSON::Serializable
  end

  # Value of the `logs:<id>` binding
  record RemoteLogsView,
    device : RemoteDebugDevice,
    # Entries ordered by `seq`, oldest first
    entries : Array(RemoteLogEntry) do
    include JSON::Serializable
  end
end
