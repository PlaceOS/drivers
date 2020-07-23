require "json"

# Models used by the OpenAccess system.
#
# NOTE: naming here must match that used by OpenAccess - struct names are passed
# as meaningful information within API requests.
module Lenel::OpenAccess::Models
  # Defines a new Lenel data type.
  private macro lnl(name, *attrs)
    record Lnl_{{name}}, {{*attrs}} do
      include JSON::Serializable

      # Name of the type as expected by the OpenAccess API endpoints.
      def self.name
        "Lnl_{{name}}"
      end

      # Allows the type to be used directly in building request bodies
      def self.to_json(json : JSON::Builder)
        json.string name
      end

      # Convert all fields of this record to a `NamedTuple`.
      #
      # This can be used to splat it's contents into arguments.
      def to_named_tuple
        {% verbatim do %}
          {% if @type.instance_vars.empty? %}
            NamedTuple.new
          {% else %}
            {
              {% for property in @type.instance_vars.map &.name %}
                {{property.id}}: {{property.id}},
              {% end %}
            }
          {% end %}
        {% end %}
      end
    end
  end

  # Checks if *type* has an accessor for every key in *named_tuple*.
  #
  # This can be to provide type checks for methods with variadic args.
  macro subset(type, named_tuple)
    \{% for prop in {{named_tuple}}.keys.reject { |key| {{type}}.has_method? key} %}
      \{{ raise "no property \"#{prop}\" in #{{{type}}}" }}
    \{% end %}
  end

  lnl AccessGroup,
    id : Int32,
    segmentid : Int32,
    name : String

  lnl Visit,
    id : Int32,
    cardholderid : Int32,
    delgatedid : Int32,
    email_include_def_recipents : Bool,
    email_include_host : Bool,
    email_include_visitor : Bool,
    email_list : String,
    lastchanged : Time,
    name : String,
    scheduled_timein : Time,
    scheduled_timeout : Time,
    signinlocationid : Int32,
    timein : Time,
    timeout : Time,
    type : Int32,
    visit_eventid : Int32,
    visit_key : String,
    visitor_id : String
end
