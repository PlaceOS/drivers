{% if env("COMPILE_DRIVER").ends_with?("_spec.cr") %}
  require "placeos-driver/driver-specs/runner"
{% else %}
  require "placeos-driver"
{% end %}

# Dynamically require the desired driver
{{ ("require \"../" + env("COMPILE_DRIVER") + "\"").id }}
