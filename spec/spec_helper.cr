require "spec"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

require "placeos-compiler"

Spec.before_suite do
  # Clone the private drivers
  PlaceOS::Compiler.clone_and_install(
    "private_drivers",
    "https://github.com/placeos/private-drivers"
  )
end
