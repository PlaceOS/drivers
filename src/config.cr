PROD = ENV["SG_ENV"]? == "production"

# Application dependencies
require "action-controller"

# Logging configuration
ActionController::Logger.add_tag request_id

logger = ActionController::Base.settings.logger
logger.level = PROD ? Logger::INFO : Logger::DEBUG
filters = PROD ? ["bearer_token", "secret", "password"] : [] of String

# Application code
require "./controllers/application"
require "./controllers/*"
require "./models/*"
require "./engine-drivers"

# Server required after application controllers
require "action-controller/server"

# Add handlers that should run before your application
ActionController::Server.before(
  HTTP::ErrorHandler.new(!PROD),
  ActionController::LogHandler.new(filters),
  HTTP::CompressHandler.new
)

# Optional support for serving of static assests
static_file_path = ENV["PUBLIC_WWW_PATH"]? || "./www"
if File.directory?(static_file_path)
  # Optionally add additional mime types
  ::MIME.register(".yaml", "text/yaml")

  # Check for files if no paths matched in your application
  ActionController::Server.before(
    ::HTTP::StaticFileHandler.new(static_file_path, directory_listing: false)
  )
end

# Configure session cookies
# NOTE:: Change these from defaults
ActionController::Session.configure do |settings|
  settings.key = ENV["COOKIE_SESSION_KEY"]? || "_spider_gazelle_"
  settings.secret = ENV["COOKIE_SESSION_SECRET"]? || "4f74c0b358d5bab4000dd3c75465dc2c"
end

APP_NAME = "Engine-Drivers"
VERSION  = "1.0.0"
