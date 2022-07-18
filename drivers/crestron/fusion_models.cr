require "xml"
require "json"

class Crestron::Fusion
  class Room
    include JSON::Serializable

    @[JSON::Field(key: "Alias")]
    getter room_alias : String?

    @[JSON::Field(key: "Assets")]
    getter assets : Array()? # TODO: ArrayOfAPI_Asset

    @[JSON::Field(key: "CustomFields")]
    getter custom_fields : Array()? # TODO: ArrayOfAPI_RoomCustomField

    @[JSON::Field(key: "Description")]
    getter description : String?

    @[JSON::Field(key: "DistributionGroupID")]
    getter distribution_group_id : String?

    @[JSON::Field(key: "EControlLink")]
    getter e_control_link : String?

    @[JSON::Field(key: "GroupwarePassword")]
    getter groupware_password : String?

    @[JSON::Field(key: "GroupwareProviderType")]
    getter groupware_provider_type : String?

    @[JSON::Field(key: "GroupwareURL")]
    getter groupware_url : String?

    @[JSON::Field(key: "GroupwareUserDomain")]
    getter groupware_user_domain : String?

    @[JSON::Field(key: "GroupwareUsername")]
    getter groupware_username : String?

    @[JSON::Field(key: "LastModified")]
    getter last_modified : Time? # TODO: dateTime

    @[JSON::Field(key: "Location")]
    getter location : String?

    @[JSON::Field(key: "LocationMap")]
    getter location_map : Array()? # TODO: ArrayOfAPI_Location

    @[JSON::Field(key: "ParentNodeID")]
    getter parent_node_id : String?

    @[JSON::Field(key: "Persons")]
    getter persons : Array()? # TODO: ArrayOfAPI_Person

    @[JSON::Field(key: "Processors")]
    getter processors : Array()? # TODO: ArrayOfAPI_Processor

    @[JSON::Field(key: "RoomID")]
    getter room_id : String?

    @[JSON::Field(key: "RoomName")]
    getter room_name : String?

    @[JSON::Field(key: "SMTPAddress")]
    getter smtp_address : String?

    @[JSON::Field(key: "TimeZoneID")]
    getter time_zone_id : String?

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
