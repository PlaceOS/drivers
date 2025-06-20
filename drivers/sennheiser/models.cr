module Sennheiser::Models
  macro def_get(name, resource)
    def {{name.id}}
        api_get({{resource}})
    end
  end

  macro def_put(name, resource, **params)
    def {{name.id}}(
        {% for param, klass in params %}
          {% optional = false %}
          {% if param.stringify.ends_with?("_") %}
            {% optional = true %}
            {% param = param.stringify[0..-2] %}
          {% end %}

          {% if klass.is_a?(RangeLiteral) %}
            {{param.id}} : Int32{% if optional %}? = nil{% end %},
          {% else %}
            {{param.id}} : {{klass}}{% if optional %}? = nil{% end %},
          {% end %}
        {% end %}
      )
        {% for param, klass in params %}
          {% if klass.is_a?(RangeLiteral) %}
            {% optional = false %}
            {% if param.stringify.ends_with?("_") %}
              {% optional = true %}
              {% param = param.stringify[0..-2] %}
            {% end %}
            {% if optional %} if {{param.id}}{% end %}
              raise ArgumentError.new("#{ {{param.stringify}} } must be within #{ {{klass}} }, was #{ {{param.id}} }") unless ({{klass}}).includes?({{param.id}})
            {% if optional %}end{% end %}
          {% end %}
        {% end %}
        
       api_put({{resource}},{
                {% for param, klass in params %}
                  {% if param.stringify.ends_with?("_") %}
                    {% param = param.stringify[0..-2] %}
                  {% end %}
                  "{{param.id.camelcase(lower: true)}}" => JSON.parse({{param.id}}.to_json),
                {% end %}
          }.to_json
       )
    end
  end

  enum Color
    LightGreen
    Green
    Blue
    Red
    Yellow
    Orange
    Cyan
    Pink
  end

  enum InstallationType
    FlushMounted
    SurfaceMounted
    Suspended
  end

  enum DetectionThreshold
    QuietRoom
    NormalRomm
    LoudRoom
  end

  enum SwitchOutput
    FarendOutput
    LocalOutput
  end

  alias MicTuple = NamedTuple(color: Color)
  alias MicCustomTuple = NamedTuple(enabled: Bool, color: Color)
end
