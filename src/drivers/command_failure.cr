module PlaceOS::Drivers
  class CommandFailure < Exception
    def initialize(@error_code = 1, message = nil)
      msg = message || "git exited with code: #{@error_code}"
      super(msg)
    end

    getter error_code : Int32
  end
end
