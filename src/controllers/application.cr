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
      Helper.get_repository_path(params["repository"]?)
    end
  end
end
