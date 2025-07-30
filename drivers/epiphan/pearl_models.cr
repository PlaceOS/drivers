require "json"

module Epiphan::PearlModels
  # Enum for recorder states
  enum RecorderState
    Started
    Stopped
    Paused
    Starting
    Stopping
  end

  # Enum for publisher/streaming states
  enum StreamingState
    Started
    Stopped
    Starting
    Stopping
  end

  # API Response wrapper - all Pearl API responses use this format
  class ApiResponse(T)
    include JSON::Serializable

    getter status : String
    getter result : T
  end

  # Represents a recording channel/recorder
  class Recorder
    include JSON::Serializable

    getter id : String
    getter name : String
    getter multisource : Bool
  end

  # Represents the status of a recorder
  class RecorderStatus
    include JSON::Serializable

    getter state : RecorderState
    getter duration : Int64? # Duration in seconds (optional)
    getter active : String?  # Number of active recordings as string (optional)
    getter total : String?   # Total number of recordings as string (optional)
  end

  # Represents a streaming channel
  class Channel
    include JSON::Serializable

    getter id : String
    getter name : String
    getter publishers : Array(Publisher)?
    getter encoders : Array(JSON::Any)?
    getter active_layout : Layout?
  end

  # Channel layout information
  class Layout
    include JSON::Serializable

    class Sources
      include JSON::Serializable

      getter video : Array(JSON::Any)?
      getter audio : Array(JSON::Any)?
    end

    getter id : String
    getter name : String
    getter sources : Sources?
  end

  # Control operation response - simple status response
  class ControlResponse
    include JSON::Serializable

    getter status : String
  end

  # Publisher status within a channel
  class PublisherStatus
    include JSON::Serializable

    getter state : StreamingState
  end

  # Publisher information
  class Publisher
    include JSON::Serializable

    getter id : String
    getter type : String # "rtmp", "rtsp", "srt", etc.
    getter name : String
    getter status : PublisherStatus?
    getter settings : JSON::Any? # PublisherSettings varies by type
  end

  # System status information
  class SystemStatus
    include JSON::Serializable

    getter cpuload : Int32?        # CPU load percentage
    getter cpuload_high : Bool?    # CPU warning
    getter cputemp : Int32?        # CPU temperature in Celsius
    getter cputemp_threshold : Int32? # High CPU temperature threshold
    getter date : Time?            # Current system time
    getter uptime : Int64?         # System uptime in seconds
  end

  # Response type aliases for specific endpoints
  alias RecordersResponse = ApiResponse(Array(Recorder))
  alias ChannelsResponse = ApiResponse(Array(Channel))
  alias RecorderStatusResponse = ApiResponse(RecorderStatus)
  alias LayoutsResponse = ApiResponse(Array(Layout))
  alias PublishersResponse = ApiResponse(Array(Publisher))
  alias SystemStatusResponse = ApiResponse(SystemStatus)
end
