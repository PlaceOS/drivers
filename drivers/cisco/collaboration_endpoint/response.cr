require "json"

module Cisco::CollaborationEndpoint::XAPI
  TRUTHY  = {"true", "available", "standby", "on", "active"}
  FALSEY  = {"false", "unavailable", "off", "inactive"}
  BOOLEAN = ->(val : String) { TRUTHY.includes?(val.downcase) }
  BOOL_OR = ->(term : String) { ->(val : String) { val == term ? term : BOOLEAN.call(val) } }
  PARSERS = {
    "TTPAR_OnOff"        => BOOLEAN,
    "TTPAR_OnOffAuto"    => BOOL_OR.call("Auto"),
    "TTPAR_OnOffCurrent" => BOOL_OR.call("Current"),
    "TTPAR_MuteEnabled"  => BOOLEAN,
  }

  def self.value_convert(value : String, valuespace : String? = nil)
    parser = PARSERS[valuespace]?
    return value.to_i64 unless parser
    parser.call(value)
  rescue
    check = value.downcase
    # probably wasn't an integer
    if check.in? TRUTHY
      true
    elsif check.in? FALSEY
      false
    else
      value
    end
  end

  def self.parse(data : String)
    JSON.parse(data).as_h.flatten_xapi_json
  end
end

module Enumerable
  alias JSONBasic = Bool | Float64 | Int64 | String | Nil
  alias JSONComplex = JSONBasic | Hash(String, JSONComplex)

  def flatten_xapi_json(parent_prefix : String? = nil, delimiter : String = "/")
    res = {} of String => JSONComplex

    self.each_with_index do |elem, i|
      if elem.is_a?(Tuple)
        k, v = elem
      else
        # this is an Array
        k, v = i, elem

        # check if there is an ID element in the child
        if id = v.as_h?.try &.delete("id")
          k = id
        end
      end

      # assign key name for result hash
      key = parent_prefix ? "#{parent_prefix}#{delimiter}#{k}" : k.to_s
      raw = v.raw

      case raw
      in Array(JSON::Any)
        # recursive call to flatten child elements
        res.merge!(raw.flatten_xapi_json(key, delimiter))
      in Hash(String, JSON::Any)
        value = raw["Value"]?
        if value && value.as_h?.nil?
          valuespaceref = raw["valueSpaceRef"]?.try &.as_s.split('/').last
          res[key] = Cisco::CollaborationEndpoint::XAPI.value_convert(value.as_s, valuespaceref)
        elsif id
          res[key] = raw.flatten_xapi_json(delimiter: delimiter)
        else
          res.merge!(raw.flatten_xapi_json(key, delimiter))
        end
      in JSONBasic
        res[key] = raw
      end
    end

    res
  end
end
