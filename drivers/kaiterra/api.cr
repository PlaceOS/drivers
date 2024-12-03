require "placeos-driver"

# https://www.kaiterra.com/dev/#overview

class Kaiterra::API < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Kaiterra API"
  generic_name :Control
  uri_base "https://api.kaiterra.com/v1"

  default_settings({
    api_key: "",
  })

  @api_key : String = ""

  def on_update
    @api_key = setting(String, :api_key)
  end

  enum Param
    Rco2   # Carbon dioxide
    Ro3    # Ozone
    Rpm25c # PM2.5
    Rpm10c # PM10
    Rhumid # Relative humidity
    Rtemp  # Temperature
    Rtvoc  # Total Volatile Organic Compounds (TVOC)
  end

  enum Unit
    Ppm                     # Parts per million (volumetric concentration)
    Ppb                     # Parts per billion
    MicrogramsPerCubicMeter # µg/m³ => Micrograms per cubic meter (mass concentration)
    MilligramsPerCubicMeter # mg/m³	=> Milligrams per cubic meter
    C                       # Degrees Celsius
    F                       # Degrees Fahrenheit
    X                       # Count of something, such as readings in a sampling interval
    Percentage              # % => Percentage, as with relative humidity

    def self.parse(string)
      case string
      when "µg/m³"
        Unit::MicrogramsPerCubicMeter
      when "mg/m³"
        Unit::MilligramsPerCubicMeter
      when "%"
        Unit::Percentage
      else
        super
      end
    end

    def self.new(pull : JSON::PullParser)
      parse(pull.read_string)
    end

    def to_s
      case self
      when Unit::MicrogramsPerCubicMeter
        "µg/m³"
      when Unit::MilligramsPerCubicMeter
        "mg/m³"
      when Unit::Percentage
        "%"
      else
        super
      end
    end
  end

  class Response
    include JSON::Serializable

    property data : Array(Data)?
    property errors : Array(JSON::Any::Type)?
  end

  class Data
    include JSON::Serializable

    property param : Param
    property units : Unit
    property source : String? # The module that captured the parameter reading
    property span : Int64     # The sampling interval, in seconds, over which this measurement was taken
    property points : Array(JSON::Any::Type)
  end

  def get_devices(id : String, params : Hash(String, String) = {} of String => String)
    response = get(
      generate_url("/devices/#{id}/top", params),
      headers: generate_headers
    )
    Response.from_json(response.body)
  end

  class Request
    include JSON::Serializable

    property method : String
    property relative_url : String
    # headers (json, optional) - A JSON array of header description objects, each of which has a name and value object
    property headers : Array(NamedTuple(name: String, value: String))?
    property body : String?
  end

  class BatchResponse
    include JSON::Serializable

    property body : String
    property code : Int64
  end

  def batch(body : Array(Request), params : Hash(String, String) = {} of String => String)
    response = post(
      generate_url("/batch", params),
      body: body.to_json,
      headers: generate_headers({
        "Content-Type"     => "application/json",
        "Content-Encoding" => "UTF-8",
      })
    )
    Array(BatchResponse).from_json(response.body)
  end

  private def generate_url(
    path : String,
    params : Hash(String, String) = {} of String => String
  )
    params["key"] = @api_key
    encoded_params = URI::Params.encode(params)
    "#{path}?#{encoded_params}"
  end

  private def generate_headers(
    headers : Hash(String, String) = {} of String => String
  )
    # Recommended to use this header in docs
    headers["Accept-Encoding"] = "gzip"
    headers
  end
end
