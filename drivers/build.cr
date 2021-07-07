{% if env("COMPILE_DRIVER") %}
  {% if env("COMPILE_DRIVER").ends_with?("_spec.cr") %}
    require "placeos-driver/spec"
  {% else %}
    require "placeos-driver"
  {% end %}

  # Dynamically require the desired driver
  {{ ("require \"../" + env("COMPILE_DRIVER") + "\"").id }}
{% end %}
