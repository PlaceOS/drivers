require "uri"
require "http/client"

class Cisco::Blinds::Client
  property base_url : String

  UP_URL   = "/room/Turing/blindsUp"
  DOWN_URL = "/room/Turing/blindsDown"
  OFF_URL  = "/room/Turing/blindsOff"

  def initialize(@base_url : String)
  end

  def up
    url = URI.parse(base_url).resolve(UP_URL).to_s
    response = HTTP::Client.get url

    raise Exception.new("Failed to raise the blinds") if response.status_code != 200
  end

  def down
    url = URI.parse(base_url).resolve(DOWN_URL).to_s
    response = HTTP::Client.get url

    raise Exception.new("Failed to lower the blinds") if response.status_code != 200
  end

  def off
    url = URI.parse(base_url).resolve(OFF_URL).to_s
    response = HTTP::Client.get url

    raise Exception.new("Failed to turn off the blinds") if response.status_code != 200
  end
end
