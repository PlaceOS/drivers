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

  # Connectivity details
  class Connectivity
    include JSON::Serializable

    getter mdns : String?
    getter dns : String?
    getter http : String?
    getter https : String?
    getter captive_portal : String?
    getter external_ip : String?
    getter icmp : String?
    getter epiphan_edge : String?
    getter vtun : String?
  end

  # Firmware Details
  class FirmwareDetails
    include JSON::Serializable

    getter version : String?
    getter revision : String?
    getter product_id : Int32?
    getter product_name : String?
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

  # Represents the base Inputs class
  class Inputs
    include JSON::Serializable

    getter id : String?
    getter name : String?
    getter status : InputStatus?
  end

  # Represents the status of an individual input
  class InputStatus
    include JSON::Serializable

    getter video : VideoInputState?
    getter audio : AudioInputState?
    getter clock_sync : Bool?
    getter connection : Connection?
    getter warnings : Array(JSON::Any)?
  end

  # Represents the status of the video component of an individual input
  class VideoInputState
    include JSON::Serializable

    getter state : String?
    getter resolution : String?
    getter actual_fps : Float64?
    getter codec : String?
    getter fps : Float64?
    getter real_device_name : String?
    getter vrr : Float64?
    getter interlaced : Bool?
    getter error : String?
  end

  # Represents the status of the audio component of an individual input
  class AudioInputState
    include JSON::Serializable

    getter state : String?
    getter levels : Levels?
    getter codec : String?
    getter sample_rate : Int32?
    getter real_device_name : String?
    getter error : String?
  end

  # Represents the connection status of an individual input
  class Connection
    include JSON::Serializable

    getter duration : Int64?
    getter state : String?
  end

  # Represents the RMS and PEAK audio levels
  class Levels
    include JSON::Serializable

    getter rms : Array(Float64)?
    getter peak : Array(Float64)?
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

    getter cpuload : Int32?           # CPU load percentage
    getter cpuload_high : Bool?       # CPU warning
    getter cputemp : Int32?           # CPU temperature in Celsius
    getter cputemp_threshold : Int32? # High CPU temperature threshold
    getter date : Time?               # Current system time
    getter uptime : Int64?            # System uptime in seconds
  end

  # Response type aliases for specific endpoints
  alias RecordersResponse = ApiResponse(Array(Recorder))
  alias ChannelsResponse = ApiResponse(Array(Channel))
  alias RecorderStatusResponse = ApiResponse(RecorderStatus)
  alias LayoutsResponse = ApiResponse(Array(Layout))
  alias PublishersResponse = ApiResponse(Array(Publisher))
  alias SystemStatusResponse = ApiResponse(SystemStatus)
  alias InputStatusResponse = ApiResponse(Array(Inputs))
  alias ConnectivityDetailsResponse = ApiResponse(Connectivity)
  alias FirmwareDetailsResponse = ApiResponse(FirmwareDetails)
end
