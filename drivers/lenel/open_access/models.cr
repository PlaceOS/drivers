require "json"

# DTO's for OpenAccess entities.
#
# These are intentionally lightweight. In cases where a entity holds a
# relationship to another, these are _not_ auto-resolved. Original ID references
# are kept in place. Types here a simply a thin wrapper for JSON serialization.
module Lenel::OpenAccess::Models
  # Base type for Lenel data objects.
  abstract struct Element
    include JSON::Serializable

    # Name of the type as expected by the OpenAccess API endpoints.
    def self.type_name
      "Lnl_#{name.rpartition("::").last}"
    end

    # Override the default JSON::Serializable behaviour to make keys case
    # inensitive when deserialising.
    #
    # The Lenel API 'features' multiple case conventions, with varying
    # consistency. It appears to be non-case sensitive for requests sent to it,
    # however as the parser here _is_ case sensitive this normalises all keys to
    # their downcased attribute equivalents.
    def initialize(*, __pull_for_json_serializable pull : ::JSON::PullParser)
      {% begin %}
        {% properties = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% properties[ivar.id] = ivar.type %}
          %var{ivar.id} = nil
        {% end %}

        pull.read_begin_object
        until pull.kind.end_object?
          key = pull.read_object_key
            case key.downcase
            {% for name, type in properties %}
              when {{name.stringify}}
                %var{name} = ::Union({{type}}).new pull
            {% end %}
            else
              pull.skip
            end
        end
        pull.read_next

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

  abstract struct Person < Element
    getter id : Int32
    getter firstname : String
    getter lastname : String
  end

  struct Badge < Element
    getter badgekey : Int32
    getter activate : Time
    getter deactivate : Time
    getter id : Int64
    getter personid : Int32
    getter status : Int32
    getter type : Int32
    getter uselimit : Int32
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
