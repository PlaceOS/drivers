require "./events"

class Cisco::DNASpaces::DeviceLocationUpdate
  include JSON::Serializable

  getter device : Device
  getter location : Location

  getter ssid : String

  @[JSON::Field(key: "rawUserId")]
  getter raw_user_id : String

  @[JSON::Field(key: "visitId")]
  getter visit_id : String

  @[JSON::Field(key: "lastSeen")]
  property last_seen : Int64

  @[JSON::Field(key: "deviceClassification")]
  getter device_classification : String

  @[JSON::Field(key: "mapId")]
  property map_id : String

  @[JSON::Field(key: "xPos")]
  getter x_pos : Float64

  @[JSON::Field(key: "yPos")]
  getter y_pos : Float64

  @[JSON::Field(key: "confidenceFactor")]
  getter confidence_factor : Float64
  getter latitude : Float64
  getter longitude : Float64
  getter unc : Float64

  @[JSON::Field(ignore: true)]
  @location_mappings : Hash(String, String)? = nil

  # Ensure we only process these once
  def location_mappings : Hash(String, String)
    if mappings = @location_mappings
      mappings
    else
      mappings = location.details
      @location_mappings = mappings
      mappings
    end
  end
end
