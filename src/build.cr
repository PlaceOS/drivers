{% unless flag?("docs") %}
  {% driver_src = env("COMPILE_DRIVER") %}

  {% if driver_src %}
    {% if driver_src.ends_with?("_spec.cr") %}
      require "driver/driver-specs/runner"
    {% else %}
      require "driver"
    {% end %}

    require "../{{driver_src.id}}"
  {% else %}
    {{ raise "Build target is not set. Use COMPILE_DRIVER env var to specify driver to build." }}
  {% end %}
{% end %}
