require "spec"

# Your application config
# If you have a testing environment, replace this with a test config file
require "../src/config"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

require "../src/engine-drivers"

# Clone the private drivers
ACAEngine::Drivers::Compiler.clone_and_install(
  "private_drivers",
  "https://github.com/aca-labs/private-crystal-engine-drivers"
)
