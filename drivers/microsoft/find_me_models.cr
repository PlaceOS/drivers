require "json"

module Microsoft
  class Level
    include JSON::Serializable

    @[JSON::Field(key: "Building")]
    getter building : String

    @[JSON::Field(key: "Level")]
    getter name : String

    @[JSON::Field(key: "Online")]
    getter online : Int32
  end

  class Coordinates
    include JSON::Serializable

    @[JSON::Field(key: "Building")]
    getter building : String

    @[JSON::Field(key: "Level")]
    getter building : String

    @[JSON::Field(key: "X")]
    getter x : Float64

    @[JSON::Field(key: "Y")]
    getter y : Float64

    @[JSON::Field(key: "Building")]
    getter building : String

    @[JSON::Field(key: "Building")]
    getter building : String
  end

  class GPS
    include JSON::Serializable

    @[JSON::Field(key: "Latitude")]
    getter latitude : Float64

    @[JSON::Field(key: "Longitude")]
    getter longitude : Float64
  end

  class UserData
    include JSON::Serializable

    @[JSON::Field(key: "Alias")]
    getter username : String

    @[JSON::Field(key: "DisplayName")]
    getter display_name : String

    @[JSON::Field(key: "EmailAddress")]
    getter email_address : String
  end

  # Example Response:
  # [{"Alias":"dwatson","LastUpdate":"2015-11-12T02:25:50.017Z","Confidence":100,
  #   "Coordinates":{"Building":"SYDNEY","Level":"2","X":76,"Y":29,"LocationDescription":"2140","MapByLocationId":true},
  #   "GPS":{"Latitude":-33.796597429,"Longitude":151.1382508278,"Accuracy":0.0,"LocationDescription":null},
  #   "LocationIdentifier":null,"Status":"Located","LocatedUsing":"FixedLocation","Type":"Person","Comments":null,
  #   "ExtendedUserData":{"Alias":"dwatson","DisplayName":"David Watson","EmailAddress":"David.Watson@microsoft.com","LyncSipAddress":"dwatson@microsoft.com"}}]
  class Location
    include JSON::Serializable

    @[JSON::Field(key: "Alias")]
    getter username : String

    @[JSON::Field(key: "LastUpdate")]
    getter last_update : String

    @[JSON::Field(key: "Confidence")]
    getter confidence : Float64

    @[JSON::Field(key: "Coordinates")]
    getter coordinates : Coordinates?

    @[JSON::Field(key: "GPS")]
    getter gps : GPS?

    @[JSON::Field(key: "Status")]
    getter status : String

    @[JSON::Field(key: "LocatedUsing")]
    getter located_using : String?

    @[JSON::Field(key: "Type")]
    getter type : String?

    @[JSON::Field(key: "ExtendedUserData")]
    getter user_data : UserData?
  end
end
