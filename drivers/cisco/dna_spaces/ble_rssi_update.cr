require "./events"
require "./location"

class Cisco::DNASpaces::BlePayload
  include JSON::Serializable

  property timestamp : Int64
  property data : String
end

class Cisco::DNASpaces::RssiMeasurement
  include JSON::Serializable

  @[JSON::Field(key: "apMacAddress")]
  property access_point_mac : String

  @[JSON::Field(key: "ifSlotId")]
  property if_slot_id : Int32

  @[JSON::Field(key: "bandId")]
  property band_id : Int32

  @[JSON::Field(key: "antennaId")]
  property antenna_id : Int32

  property rssi : Int32
  property timestamp : Int64
end

class Cisco::DNASpaces::RssiNotification
  include JSON::Serializable

  @[JSON::Field(key: "macAddress")]
  property mac_address : String

  @[JSON::Field(key: "apRssiMeasurements")]
  property measurements : Array(RssiMeasurement)

  @[JSON::Field(key: "blePayload")]
  property payload : BlePayload
end

class Cisco::DNASpaces::BleRssiUpdate
  include JSON::Serializable

  @[JSON::Field(key: "rssiNotification")]
  getter notification : RssiNotification
  getter location : Location
end
