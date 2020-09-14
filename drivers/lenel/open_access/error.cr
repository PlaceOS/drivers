require "json"

class Lenel::OpenAccess::Error < Exception
  alias Info = { code: String, message: String? }

  def self.from_response(response)
    if error = response.headers["error"]?.try &->Info.from_json(String)
      new **error
    else
      new response.inspect
      # new response.status.to_s
    end
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
