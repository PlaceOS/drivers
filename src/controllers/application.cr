require "uuid"
require "action-controller"

module PlaceOS::Drivers::Api
  abstract class Application < ActionController::Base
    before_action :set_request_id

    # Support request tracking
    def set_request_id
      request_id = UUID.random.to_s
      Log.context.set(
        client_ip: client_ip,
        request_id: request_id
      )
      response.headers["X-Request-ID"] = request_id
    end

    # Builds and validates the selected repository
    def get_repository_path
      Helper.get_repository_path(params["repository"]?)
    end
  end
end
