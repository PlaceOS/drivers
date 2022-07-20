require "xml"
require "json"

class Crestron::Fusion
  class Action
    include JSON::Serializable

    @[JSON::Field(key: "ActionDescription")]
    property action_description : String?

    # Max 50 characters
    @[JSON::Field(key: "ActionID")]
    property action_id : String?

    # Max 128 characters
    @[JSON::Field(key: "ActionName")]
    property action_name : String?

    @[JSON::Field(key: "IsOverride")]
    property is_override : Bool?

    @[JSON::Field(key: "LastModified")]
    property last_modified : Time?

    @[JSON::Field(key: "OffsetMinutes")]
    property off_set_minutes : Int64?

    @[JSON::Field(key: "OverriddenActionID")]
    property overridden_action_id : String?

    @[JSON::Field(key: "StepList")]
    property step_list : Array(ActionStep)?

    def self.from_xml(xml : String) : self
      self.from_xml(XML.parse(xml))
    end

    def self.from_xml(node : XML::Node) : self
      # TODO: create model from xml nodes
    end
  end

  class ActionStep
    include JSON::Serializable

    @[JSON::Field(key: "AnalogValue")]
    property analog_value : Int64?

    # Max 50 characters
    @[JSON::Field(key: "AttributeID")]
    property attribute_id : String?

    @[JSON::Field(key: "AttributeType")]
    property attribute_type : AttributeType? 

    @[JSON::Field(key: "DigitalValue")]
    property digital_value : Bool?

    @[JSON::Field(key: "LastModified")]
    property last_modified : Time?

    @[JSON::Field(key: "OrderIndex")]
    property order_index : Int64?

    @[JSON::Field(key: "SerialValue")]
    property serial_value : String?

    def self.from_xml(xml : String) : self
      self.from_xml(XML.parse(xml))
    end

    def self.from_xml(node : XML::Node) : self
      # TODO: create model from xml nodes
    end
  end



  enum AttributeType
    Unknown = 0
    AppStore = 1
    Enterprise = 2
    Mdm = 3
    Other = 4
  end

  # TODO: API_Asset
  # TODO: Appointment type
  # TODO: Connection type
  # TODO: API_RoomCustomField
  # TODO: API_Location
  # TODO: API_Person
  # TODO: API_Processor

  class Room
    include JSON::Serializable

    @[JSON::Field(key: "Actions")]
    property actions : Array(Action)?

    # Max 255 characters
    @[JSON::Field(key: "AdjacentToLocation")]
    property adjacent_to_location : String?

    # Max 255 characters
    @[JSON::Field(key: "AirMediaInfo")]
    property air_media_info : String?

    # Max 255 characters
    @[JSON::Field(key: "Alias")]
    property room_alias : String?

    @[JSON::Field(key: "Appointments")]
    property appointments : Array(Appointment)?

    @[JSON::Field(key: "Assets")]
    property assets : Array(Asset)?

    @[JSON::Field(key: "AssetTypes")]
    property asset_types : Array(String)?

    # Unknown type, taking a guess
    @[JSON::Field(key: "AssociatedBLDIDs")]
    property associated_blue_tooth_ids : Array(String)?

    @[JSON::Field(key: "Availability")]
    property availability : Bool?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Bookable")]
    property availability : Bool?

    # Time span in minutes.
    # Unknown type, taking a guess
    @[JSON::Field(key: "BookedUntil")]
    property booked_until : Int64?

    @[JSON::Field(key: "BookedUntilTime")]
    property booked_until_time : Time?

    # Unknown type, taking a guess
    @[JSON::Field(key: "BranchMajorID")]
    property branch_major_id : String?

    @[JSON::Field(key: "BranchUUID")]
    property branch_uuid : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Capacity")]
    property capacity : Int64?

    @[JSON::Field(key: "Connections")]
    property connections : Array(Connection)?

    # Unknown type, taking a guess
    @[JSON::Field(key: "ConnectionSetID")]
    property connection_set_id : String?

    @[JSON::Field(key: "CustomFields")]
    property custom_fields : Array(RoomCustomField)?

    @[JSON::Field(key: "Description")]
    property description : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Distance")]
    property distance : String?

    # Max 50 characters
    @[JSON::Field(key: "DistributionGroupID")]
    property distribution_group_id : String?

    # Max 255 characters
    @[JSON::Field(key: "EControlLink")]
    property e_control_link : String?

    # Max 255 characters
    @[JSON::Field(key: "EndPointType")]
    property end_point_type : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "FutureAvailability")]
    property future_availability : String?

    @[JSON::Field(key: "FutureScheduledTime")]
    property future_scheduled_time : Time?

    # Max 350 characters
    @[JSON::Field(key: "GroupwarePassword")]
    property groupware_password : String?

    # Max 10 characters
    # Valid options:
    # - None
    # - Exchange
    # - EWS
    # - Internal
    # - Domino
    # - Micros
    # - R25
    # - External
    # - Google
    @[JSON::Field(key: "GroupwareProviderType")]
    property groupware_provider_type : String?

    # Max 255 characters
    @[JSON::Field(key: "GroupwareURL")]
    property groupware_url : String?

    # Max 255 characters
    @[JSON::Field(key: "GroupwareUserDomain")]
    property groupware_user_domain : String?

    # Max 128 characters
    @[JSON::Field(key: "GroupwareUsername")]
    property groupware_username : String?

    @[JSON::Field(key: "LastModified")]
    property last_modified : Time?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Latitude")]
    property latitude : Float32?

    # Max 255 characters
    @[JSON::Field(key: "Location")]
    property location : String?

    @[JSON::Field(key: "LocationMap")]
    property location_map : Array(Location)?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Longitude")]
    property longitude : Float32?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Nearby")]
    property nearby : Bool?

    # Max 50 characters
    @[JSON::Field(key: "ParentNodeID")]
    property parent_node_id : String?

    @[JSON::Field(key: "Persons")]
    property persons : Array(Person)?

    @[JSON::Field(key: "Processors")]
    property processors : Array(Processor)?

    @[JSON::Field(key: "Region")]
    property region : String?

    # Max 255 characters
    @[JSON::Field(key: "RoomCategory")]
    property room_category : String?

    # Max 50 characters
    @[JSON::Field(key: "RoomID")]
    property room_id : String?

    @[JSON::Field(key: "RoomImageURLs")]
    property room_image_urls : Array(String)?

    # Max 128 characters
    @[JSON::Field(key: "RoomName")]
    property room_name : String?

    # Max 512 characters
    @[JSON::Field(key: "SMTPAddress")]
    property smtp_address : String?

    @[JSON::Field(key: "State")]
    property state : String?

    @[JSON::Field(key: "Status")]
    property status : String?

    @[JSON::Field(key: "Symbols")]
    property symbols : Array(String)?

    # Max 255 characters
    @[JSON::Field(key: "TimeZoneID")]
    property time_zone_id : String?

    # Max 255 characters
    @[JSON::Field(key: "WebCamLink")]
    property web_cam_link : String?

    def self.from_xml(xml : String) : self
      self.from_xml(XML.parse(xml))
    end

    def self.from_xml(node : XML::Node) : self
      # TODO: create model from xml nodes
    end
  end
end
