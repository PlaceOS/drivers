require "placeos-driver"

# https://www.kaiterra.com/dev/#overview

class Kaiterra::API < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Kaiterra API"
  generic_name :Control
  uri_base "https://api.kaiterra.com/v1"

  default_settings({
    api_key: "",
    device_ids: [] of String
  })

  @api_key : String = ""
  @device_ids : Array(String) = [] of String

  TIME_FORMAT = "%m/%d/%Y %H:%M%S"

  def on_load
    on_update
  end

  def on_update
    @api_key = setting?(String, :api_key) || ""
    @device_ids = setting?(Array(String), :device_ids) || [] of String
  end

  # Supported values for query string parameter Air Quality Index
  enum AQI
    Cn
    In
    Us
  end

  enum Param
    Rco2 # Carbon dioxide
    Ro3 # Ozone
    Rpm25c # PM2.5
    Rpm10c # PM10
    Rhumid # Relative humidity
    Rtemp # Temperature
    Rtvoc # Total Volatile Organic Compounds (TVOC)
  end

  enum Unit
    Ppm # Parts per million (volumetric concentration)
    Ppb # Parts per billion
    MicrogramsPerCubicMeter # µg/m³ => Micrograms per cubic meter (mass concentration)
    MilligramsPerCubicMeter # mg/m³	=> Milligrams per cubic meter
    C # Degrees Celsius
    F # Degrees Fahrenheit
    X # Count of something, such as readings in a sampling interval
    Percentage # % => Percentage, as with relative humidity

    def self.parse(string)
      case string
    	when "µg/m³"
        Unit::MicrogramsPerCubicMeter
      when "mg/m³"
        Unit::MilligramsPerCubicMeter
    	when "%"
    		Unit::Percentage
      else
        self.parse(string)
      end
    end

    def self.new(pull : JSON::PullParser)
      self.parse(pull.read_string)
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
        self.to_s
      end
    end
  end

  class Response
    include JSON::Serializable

    property data : Array(Data)
  end

  class Data
    include JSON::Serializable

    property param : Param
    property units : Unit
    property source : String? # The module that captured the parameter reading
    property span : Int64 # The sampling interval, in seconds, over which this measurement was taken
    property points : Array(JSON::Any::Type)
  end

  def get_devices(id : String)
    response = get_request("/devices/#{id}/top")
    Response.from_json(response.body)
  end

  class Request
    include JSON::Serializable

    property method : String
    property relative_url : String
    property headers : JSON::Any::Type?
    property body : String?
  end

  class BatchResponse
    include JSON::Serializable

    property body : String
    property code : Int64
  end

  def batch(body : Array(Request), include_headers : Bool = false)
    response = get_request(
      "/batch?include_headers=#{include_headers}",
      headers: {
        "Content-Type" => "application/json",
        "Content-Encoding" => "UTF-8"
      }
    )
    Array(BatchResponse).from_json(response.body)
  end

  private def get_request(
    path : String,
    aqi : AQI? = nil,
    headers : Hash(String, String) = {} of String => String
  )
    # Recommended to use this header in docs
    headers["Accept-Encoding"] = "gzip"
    get("#{path}?api-key=#{@api_key}", headers: headers)
  end
end
