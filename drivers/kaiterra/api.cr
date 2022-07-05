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

    def self.new(pull : JSON::PullParser)
      case string = pull.read_string
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
    get_request("/devices/#{id}/top")
    Response.from_json(response.body)
  end

  def get_request(path : String, aqi : AQI? = nil)
    # Recommended to use these headers in docs
    headers = {
      "Accept-Encoding" => "gzip",
      "Content-Encoding" => "UTF-8"
    }
    get(path, headers: headers)
  end
end
