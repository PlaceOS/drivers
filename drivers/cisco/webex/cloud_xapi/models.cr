module CloudXAPI::Models
  enum Colour
    Green
    Yellow
    Red
    Purple
    Blue
    Orange
    Orchid
    Aquamarine
    Fuchsia
    Violet
    Magenta
    Scarlet
    Gold
    Lime
    Turquoise
    Cyan
    Off

    def to_json(json : JSON::Builder)
      json.string(to_s)
    end
  end

  record DeviceToken, expires_in : Int64, token_type : String, refresh_token : String, refresh_token_expires_in : Int64,
    access_token : String do
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter! expiry : Time

    @[JSON::Field(ignore: true)]
    getter! refresh_expiry : Time

    def after_initialize
      @expiry = Time.utc + expires_in.seconds
      @refresh_expiry = Time.utc + refresh_token_expires_in.seconds
    end

    def auth_token
      "#{token_type} #{access_token}"
    end
  end

  enum TextInputType
    SingleLine
    Numeric
    Password
    PIN
  end

  enum TextKeyboardState
    Open
    Closed
  end

  macro command(cmd_name, **params)
    {% for cmd, name in cmd_name %}
      def {{name.id}}(device_id : String,
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

        command({{cmd.split(" ").join(".")}},{
            "deviceId" => JSON::Any.new(device_id),
            {% if params.size > 0 %}
              "arguments" => {
                {% for param, klass in params %}
                  {% if param.stringify.ends_with?("_") %}
                    {% param = param.stringify[0..-2] %}
                  {% end %}
                  "{{param.id.capitalize}}" => JSON.parse({{param.id}}.to_json),
                {% end %}
              } of String => JSON::Any
            {% end %}
          }.to_json
        )
      end
    {% end %}
  end
end
