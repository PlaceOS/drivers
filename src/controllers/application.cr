require "uuid"

abstract class Application < ActionController::Base
  before_action :set_request_id

  def set_request_id
    # Support request tracking
    response.headers["X-Request-ID"] = request.id = request.headers["X-Request-ID"]? || UUID.random.to_s
  end
end
