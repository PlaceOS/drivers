require "json"
require "./response"
require "./feedback"

# monkey patching task is how we attach custom data
# request_payload is set by send if it's defined
class ::PlaceOS::Driver::Task
  getter request_payload : String? = nil

  def request_payload=(payload : String)
    @request_payload = payload.split("\n")[0]
  end

  alias ResponseCallback = Proc(Hash(String, Enumerable::JSONComplex), Hash(String, Enumerable::JSONComplex) | Enumerable::JSONComplex | Symbol)
  property xapi_request_id : String? = nil
  property xapi_callback : ResponseCallback? = nil
end

module Cisco::CollaborationEndpoint::XAPI
  # Regexp's for tokenizing the xAPI command and response structure.
  INVALID_COMMAND = /(?<=Command not recognized\.)[\r\n]+/

  SUCCESS = /(?<=OK)[\r\n]+/

  COMMAND_RESPONSE = Regex.union(INVALID_COMMAND, SUCCESS)

  LOGIN_COMPLETE = /Login successful/

  enum ActionType
    XConfiguration
    XCommand
    XStatus
    XFeedback
    XPreferences
  end

  enum FeedbackAction
    Register
    Deregister
    DeregisterAll
    List
  end

  # Serialize an xAPI action into transmittable command.
  def self.create_action(
    __action__ : ActionType,
    *args,
    hash_args : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type,
    priority : Int32? = nil, # we want to ignore this param, hence we specified it here
    **kwargs
  )
    [
      __action__.to_s.camelcase(lower: true),
      args.compact_map(&.to_s),
      hash_args.map { |key, value|
        if value
          value = "\"#{value}\"" if value.is_a? String
          "#{key.to_s.camelcase}: #{value}"
        end
      },
      kwargs.map { |key, value|
        if value
          value = "\"#{value}\"" if value.is_a? String
          "#{key.to_s.camelcase}: #{value}"
        end
      }.to_a.compact!,
    ].flatten.join " "
  end

  # Serialize an xCommand into transmittable command.
  def self.xcommand(
    path : String,
    hash_args : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type,
    **kwargs
  )
    create_action ActionType::XCommand, path, **kwargs.merge({hash_args: hash_args})
  end

  # Serialize an xConfiguration action into a transmittable command.
  def self.xconfiguration(path : String, setting : String, value : JSON::Any::Type)
    create_action ActionType::XConfiguration, path, hash_args: {
      setting => value,
    }
  end

  # Serialize an xStatus request into transmittable command.
  def self.xstatus(path : String)
    create_action ActionType::XStatus, path
  end

  # Serialize a xFeedback subscription request.
  def self.xfeedback(action : FeedbackAction, path : String? = nil)
    if path
      xpath = tokenize path
      create_action ActionType::XFeedback, action, "/#{xpath.join('/')}"
    else
      create_action ActionType::XFeedback, action
    end
  end

  def self.tokenize(path : String)
    # Allow space or slash seperated paths
    path.split(/[\s\/\\]/).reject(&.empty?)
  end

  macro command(cmd_name, **params)
    {% for cmd, name in cmd_name %}
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

        # send the command
        xcommand(
          {{cmd}},
          {% for param, klass in params %}
            {% if param.stringify.ends_with?("_") %}
              {% param = param.stringify[0..-2] %}
            {% end %}

            {{param.id}}: {{param.id}},
          {% end %}
        )
      end
    {% end %}
  end
end
