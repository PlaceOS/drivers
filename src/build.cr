{% if env("COMPILE_DRIVER").ends_with?("_spec.cr") %}
  require "driver/engine-specs/runner"
{% else %}
  require "driver"
{% end %}

# Dynamically require the desired driver
{{ ("require \"../" + env("COMPILE_DRIVER") + "\"").id }}
