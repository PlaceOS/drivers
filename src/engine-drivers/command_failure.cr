module ACAEngine::Drivers
  class CommandFailure < Exception
    def initialize(@error_code = 1)
      super("git exited with code: #{@error_code}")
    end

    getter error_code : Int32
  end
end
