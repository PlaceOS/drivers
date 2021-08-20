require "json"

# Ensure that UTC time strings provide the offset as "+00:00" instead of "Z", as required by Openaccess
module Lenel::TimeConverter
  def self.to_json(value : Time, json : JSON::Builder)
    json.string(value.to_s("%FT%T:z"))
  end
end

# DTO's for OpenAccess entities.
#
# These are intentionally lightweight. In cases where a entity holds a
# relationship to another, these are _not_ auto-resolved. Original ID references
# are kept in place. Types here a simply a thin wrapper for JSON serialization.
module Lenel::OpenAccess::Models
  PROPERTIES_KEY = "property_value_map"

  # Base type for Lenel data objects.
  abstract struct Element
    include JSON::Serializable

    # Name of the type as expected by the OpenAccess API endpoints.
    def self.type_name
      "Lnl_#{name.rpartition("::").last}"
    end

    # The Lenel API 'features' multiple case conventions, with varying
    # consistency. It appears to be non-case sensitive for requests sent to it,
    # however as response parsing _is_ more strict raw keys should come via first.
    protected def normalise(key : String) : String
      key.downcase
    end

    # Override the default JSON::Serializable behaviour to make keys case
    # inensitive when deserialising.
    def initialize(*, __pull_for_json_serializable pull : ::JSON::PullParser)
      {% begin %}
        {% properties = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% ann = ivar.annotation(::JSON::Field) %}
          {% unless ann && ann[:ignore] %}
            {% properties[ivar.id] = ivar.type %}
            %var{ivar.id} = nil
          {% end %}
        {% end %}

        # All entities come wrapeed inside a standard key...
        pull.on_key! PROPERTIES_KEY do

          pull.read_begin_object
          until pull.kind.end_object?
            %key_location = pull.location
            key = normalise pull.read_object_key
            case key
            {% for name, type in properties %}
              when {{name.stringify}}
                %var{name} = ::Union({{type}}).new pull
            {% end %}
            else
              on_unknown_json_attribute(pull, key, %key_location)
            end
          end
          pull.read_next

        end

        {% for name, type in properties %}
          @{{name}} = %var{name}.as {{type}}
        {% end %}
      {% end %}
    end

    # Provide a compile-time check to ensure *properties* is a subset of *self*.
    def self.partial(**properties : **T) : T forall T
      {% for key in T.keys %}
        {% raise %(no "#{key}" property on #{@type.name}) unless @type.has_method? key %}
      {% end %}
      properties
    end
  end

  struct Untyped < Element
    include JSON::Serializable::Unmapped
    forward_missing_to json_unmapped
  end

  struct Event < Element
    getter serial_number : Int32?

    @[JSON::Field(converter: Lenel::TimeConverter)]
    getter timestamp : Time

    getter description : String?
    getter controller_id : Int32?
    getter device_id : Int32?
    getter subdevice_id : Int32?
    getter segment_id : Int32?
    getter event_type : Int32
    getter event_subtype : Int32?
    getter event_text : String?
    getter badge_id : Int32?
    getter badge_id_str : String?
    getter badge_extended_id : String?
    getter badge_issue_code : Int32?
    getter asset_id : Int32?
    getter cardholder_key : Int32?
    getter alarm_priority : Int32?
    getter alarm_ack_blue_channel : Int32?
    getter alarm_ack_green_channel : Int32?
    getter alarm_ack_red_channel : Int32?
    getter alarm_blue_channel : Int32?
    getter alarm_green_channel : Int32?
    getter alarm_red_channel : Int32?
    getter access_result : Int32?
    getter cardholder_entered : Bool?
    getter duress : Bool?
    getter controller_name : String?
    getter event_source_name : String?
    getter cardholder_first_name : String?
    getter cardholder_last_name : String?
    getter device_name : String?
    getter subdevice_name : String?
    getter must_acknowledge : Bool?
    getter must_mark_in_progress : Bool?
  end

  abstract struct Person < Element
    getter id : Int32
    getter firstname : String
    getter lastname : String
  end

  struct Badge < Element
    getter badgekey : Int32

    @[JSON::Field(converter: Lenel::TimeConverter)]
    getter activate : Time?

    @[JSON::Field(converter: Lenel::TimeConverter)]
    getter deactivate : Time?

    getter id : Int64?
    getter personid : Int32?
    getter status : Int32?
    getter type : Int32?
    getter uselimit : Int32?
  end

  struct BadgeType < Element
    enum BadgeTypeClass
      Standard
      Temporary
      Visitor
      Guest
      SpecialPurpose
    end
    getter id : Int32
    getter name : String
    getter badgetypeclass : BadgeTypeClass
    getter usemobilecredential : Bool
  end

  struct Cardholder < Person
    getter email : String
  end
end
