{% if env("COMPILE_DRIVER").ends_with?("_spec.cr") %}
  require "engine-driver/engine-specs/runner"
{% else %}
  require "engine-driver"
{% end %}

# Dynamically require the desired driver
{{ ("require \"../" + env("COMPILE_DRIVER") + "\"").id }}
