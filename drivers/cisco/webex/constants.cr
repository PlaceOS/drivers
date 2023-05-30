module Cisco
  module Webex
    module Constants
      VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

      STATUS_CODES = {
        200 => "Successful request with body content.",
        204 => "Successful request without body content.",
        400 => "The request was invalid or cannot be otherwise served.",
        401 => "Authentication credentials were missing or incorrect.",
        403 => "The request is understood, but it has been refused or access is not allowed.",
        404 => "The URI requested is invalid or the resource requested, such as a user, does not exist. Also returned when the requested format is not supported by the requested method.",
        405 => "The request was made to a resource using an HTTP request method that is not supported.",
        409 => "The request could not be processed because it conflicts with some established rule of the system. For example, a person may not be added to a room more than once.",
        410 => "The requested resource is no longer available.",
        415 => "The request was made to a resource without specifying a media type or used a media type that is not supported.",
        423 => "The requested resource is temporarily unavailable. A `Retry-After` header may be present that specifies how many seconds you need to wait before attempting the request again.",
        429 => "Too many requests have been sent in a given amount of time and the request has been rate limited. A `Retry-After` header should be present that specifies how many seconds you need to wait before a successful request can be made.",
        500 => "Something went wrong on the server. If the issue persists, feel free to contact the Webex Developer Support team (https://developer.webex.com/support).",
        502 => "The server received an invalid response from an upstream server while processing the request. Try again later.",
        503 => "Server is overloaded with requests. Try again later.",
      }

      DEFAULT_BASE_URL               = "https://webexapis.com/v1/"
      DEFAULT_DEVICE_URL             = "https://wdm-a.wbx2.com/wdm/api/v1/"
      DEFAULT_SINGLE_REQUEST_TIMEOUT = 60
      DEFAULT_WAIT_ON_RATE_LIMIT     = true

      DEVICE = {
        "deviceType"     => "DESKTOP",
        "localizedModel" => "crystal",
        "model"          => "crystal",
        "name"           => UUID.random.to_s,
        "systemName"     => "webex-bot-client",
        "systemVersion"  => VERSION,
      }

      ROOMS_ENDPOINT    = "rooms"
      PEOPLE_ENDPOINT   = "people"
      MESSAGES_ENDPOINT = "messages"

      WEBEX_TEAMS_DATETIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"
    end
  end
end
