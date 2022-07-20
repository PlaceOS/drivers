require "xml"
require "json"

class Crestron::Fusion

  class Response
    include JSON::Serializable

  end


  class Room
    include JSON::Serializable

    @[JSON::Field(key: "Actions")]
    getter actions : Array(Action)? # TODO: API_Action

    # Max 255 characters
    @[JSON::Field(key: "AdjacentToLocation")]
    getter adjacent_to_location : String?

    # Max 255 characters
    @[JSON::Field(key: "AirMediaInfo")]
    getter air_media_info : String?

    # Max 255 characters
    @[JSON::Field(key: "Alias")]
    getter room_alias : String?

    @[JSON::Field(key: "Appointments")]
    getter appointments : Array()? # TODO: ???? type

    @[JSON::Field(key: "Assets")]
    getter assets : Array(Asset)? # TODO: API_Asset

    @[JSON::Field(key: "AssetTypes")]
    getter asset_types : Array(String)?

    # Unknown type, taking a guess
    @[JSON::Field(key: "AssociatedBLDIDs")]
    getter associated_blue_tooth_ids : Array(String)?

    @[JSON::Field(key: "Availability")]
    getter availability : Bool?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Bookable")]
    getter availability : Bool?

    # Time span in minutes.
    # Unknown type, taking a guess
    @[JSON::Field(key: "BookedUntil")]
    getter booked_until : Int32? # TODO: Time::Span converter for minutes

    @[JSON::Field(key: "BookedUntilTime")]
    getter booked_until_time : Time?

    # Unknown type, taking a guess
    @[JSON::Field(key: "BranchMajorID")]
    getter branch_major_id : String?

    @[JSON::Field(key: "BranchUUID")]
    getter branch_uuid : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Capacity")]
    getter capacity : Int32?

    @[JSON::Field(key: "Connections")]
    getter connections : Array()? # TODO: ???? type

    # Unknown type, taking a guess
    @[JSON::Field(key: "ConnectionSetID")]
    getter connection_set_id : String?

    @[JSON::Field(key: "CustomFields")]
    getter custom_fields : Array()? # TODO: API_RoomCustomField

    @[JSON::Field(key: "Description")]
    getter description : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Distance")]
    getter distance : String?

    # Max 50 characters
    @[JSON::Field(key: "DistributionGroupID")]
    getter distribution_group_id : String?

    # Max 255 characters
    @[JSON::Field(key: "EControlLink")]
    getter e_control_link : String?

    # Max 255 characters
    @[JSON::Field(key: "EndPointType")]
    getter end_point_type : String?

    # Unknown type, taking a guess
    @[JSON::Field(key: "FutureAvailability")]
    getter future_availability : String?

    @[JSON::Field(key: "FutureScheduledTime")]
    getter future_scheduled_time : Time?

    # Max 350 characters
    @[JSON::Field(key: "GroupwarePassword")]
    getter groupware_password : String?

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
    getter groupware_provider_type : String?

    # Max 255 characters
    @[JSON::Field(key: "GroupwareURL")]
    getter groupware_url : String?

    # Max 255 characters
    @[JSON::Field(key: "GroupwareUserDomain")]
    getter groupware_user_domain : String?

    # Max 128 characters
    @[JSON::Field(key: "GroupwareUsername")]
    getter groupware_username : String?

    @[JSON::Field(key: "LastModified")]
    getter last_modified : Time?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Latitude")]
    getter latitude : Float32?

    # Max 255 characters
    @[JSON::Field(key: "Location")]
    getter location : String?

    @[JSON::Field(key: "LocationMap")]
    getter location_map : Array()? # TODO: API_Location

    # Unknown type, taking a guess
    @[JSON::Field(key: "Longitude")]
    getter longitude : Float32?

    # Unknown type, taking a guess
    @[JSON::Field(key: "Nearby")]
    getter nearby : Bool?

    # Max 50 characters
    @[JSON::Field(key: "ParentNodeID")]
    getter parent_node_id : String?

    @[JSON::Field(key: "Persons")]
    getter persons : Array()? # TODO: API_Person

    @[JSON::Field(key: "Processors")]
    getter processors : Array()? # TODO: API_Processor

    @[JSON::Field(key: "Region")]
    getter region : String?

    # Max 255 characters
    @[JSON::Field(key: "RoomCategory")]
    getter room_category : String?

    # Max 50 characters
    @[JSON::Field(key: "RoomID")]
    getter room_id : String?

    @[JSON::Field(key: "RoomImageURLs")]
    getter room_image_urls : Array(String)?

    # Max 128 characters
    @[JSON::Field(key: "RoomName")]
    getter room_name : String?

    # Max 512 characters
    @[JSON::Field(key: "SMTPAddress")]
    getter smtp_address : String?

    @[JSON::Field(key: "State")]
    getter state : String?

    @[JSON::Field(key: "Status")]
    getter status : String?

    @[JSON::Field(key: "Symbols")]
    getter symbols : Array(String)?

    # Max 255 characters
    @[JSON::Field(key: "TimeZoneID")]
    getter time_zone_id : String?

    # Max 255 characters
    @[JSON::Field(key: "WebCamLink")]
    getter web_cam_link : String?

    def self.from_xml(xml : String) : self
      self.from_xml(XML.parse(xml))
    end

    def self.from_xml(node : XML::Node) : self
      # TODO: create model from xml nodes
    end
  end
end
