require "uuid"
require "action-controller"

module PlaceOS::Drivers::Api
  abstract class Application < ActionController::Base
    before_action :set_request_id

    # Support request tracking
    def set_request_id
      Log.context.set(client_ip: client_ip)
      response.headers["X-Request-ID"] = Log.context.metadata[:request_id].as_s
    end

    # Builds and validates the selected repository
    def get_repository_path
      Compiler::Helper.get_repository_path(params["repository"]?)
    end
  end
end
