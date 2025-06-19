require "json"

module Epiphan::PearlModels
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

    getter state : String
    getter duration : Int64?
    getter filename : String?
  end

  # Represents a streaming channel
  class Channel
    include JSON::Serializable

    getter id : String
    getter name : String
    getter type : String
  end

  # Channel layout information
  class Layout
    include JSON::Serializable

    getter id : String
    getter name : String
    getter active : Bool
  end

  # Control operation response - simple status response
  class ControlResponse
    include JSON::Serializable

    getter status : String
  end

  # Response type aliases for specific endpoints
  alias RecordersResponse = ApiResponse(Array(Recorder))
  alias ChannelsResponse = ApiResponse(Array(Channel))
  alias RecorderStatusResponse = ApiResponse(RecorderStatus)
  alias LayoutsResponse = ApiResponse(Array(Layout))
end
