require "json"

class Lenel::OpenAccess::Error < Exception
  alias Info = {error: {code: String, message: String?}}

  def self.from_response(response)
    # Although the API docs specify this is being in an "error" header, this
    # appars as JSON within the response body when tested with OpenAccess 7.5
    error = Error::Info.from_json response.body
    new **error[:error]
  rescue
    new response.status.to_s
  end

  getter code

  def initialize(@code : String, message : String? = nil)
    if message
      super "#{message} (#{code})"
    else
      super code
    end
  end
end
