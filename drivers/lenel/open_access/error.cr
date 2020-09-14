class Lenel::OpenAccess::Error < Exception
  def self.from_response(response)
    if error = response.headers["error"]?
      # FIXME: temp for checking header format
      new "", error
    else
      new "HTTP #{response.status}"
    end
  end

  def initialize(@code : String, @message : String? = nil)
  end

  getter code

  def to_s(io : IO) : Nil
    io << "#{message} (#{code})"
  end
end
