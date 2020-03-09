require "uuid"
require "action-controller"

module PlaceOS::Drivers::Api
  abstract class Application < ActionController::Base
    before_action :set_request_id

    def set_request_id
      # Support request tracking
      response.headers["X-Request-ID"] = logger.request_id = request.headers["X-Request-ID"]? || UUID.random.to_s
    end

    # Builds and validates the selected repository
    def get_repository_path
      repository = params["repository"]?
      if repository
        repo = File.expand_path(File.join(Compiler.repository_dir, repository))
        valid = repo.starts_with?(Compiler.repository_dir) && repo != "/" && repository.size > 0 && !repository.includes?("/") && !repository.includes?(".")
        raise "invalid repository: #{repository}" unless valid
        repo
      else
        Compiler.drivers_dir
      end
    end
  end
end
