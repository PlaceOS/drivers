require "json"

module Webex::BoolConverter
  def self.from_json(value : JSON::PullParser) : Bool
    Bool.from_json(value.read_string)
  end

  def self.to_json(value : Bool, json : JSON::Builder)
    json.string(value.to_s)
  end
end

struct MeetingParameters
  include JSON::Serializable
  getter title : String
  getter agenda : String?
  getter password : String?
  getter start : String
  getter end : String
  getter timezone : String?
  getter recurrence : String?
  getter enabledAutoRecordMeeting : Bool?
  getter allowAnyUserToBeCoHost : Bool?
  getter enabledJoinBeforeHost : Bool?
  getter enableConnectAudioBeforeHost : Bool?
  getter joinBeforeHostMinutes : Int64?
  getter excludePassword : Bool?
  getter publicMeeting : Bool?
  getter reminderTime : Int64?
  getter enableAutomaticLock : Bool?
  getter automaticLockMinutes : Int64?
  getter allowFirstUserToBeCoHost : Bool?
  getter allowAuthenticatedDevices : Bool?
  getter invitees : Array(Invites)?
  getter sendEmail : Bool?
  getter hostEmail : String?
  getter siteUrl : String?
  getter registration : RegistrationRequest?
  getter integrationTags : Array(String)?
end

struct MeetingResponse
  include JSON::Serializable

  getter id : String
  getter meetingNumber : String
  getter title : String
  getter agenda : String
  getter password : String
  getter phoneAndVideoSystemPassword : String
  getter meetingType : MeetingType
  getter state : State
  getter timezone : String
  getter start : String
  getter end : String
  getter recurrence : String
  getter hostUserId : String
  getter hostDisplayName : String
  getter hostEmail : String
  getter hostKey : String
  getter siteUrl : String
  getter webTelephonyLink : String?
  getter sipAddress : String
  getter dialInIpAddress : String
  getter roomId : String?
  getter enabledAutoRecordMeeting : Bool
  getter allowAnyUserToBeCoHost : Bool
  getter enabledJoinBeforeHost : Bool
  getter enableConnectAudioBeforeHost : Bool
  getter joinBeforeHostMinutes : Int64
  getter excludePassword : Bool
  getter publicMeeting : Bool
  getter reminderTime : Int64
  getter sessionTypeId : Int64
  getter scheduledType : ScheduledType
  getter enabledWebcastView : Bool?
  getter panelistPassword : String?
  getter phoneAndVideoSystemPanelistPassword : String?
  getter enableAutomaticLock : Bool
  getter automaticLockMinutes : Int64
  getter allowFirstUserToBeCoHost : Bool
  getter allowAuthenticatedDevices : Bool
  getter telephony : Telephony
  getter invitees : Array(Invites)?
  getter registration : RegistrationResponse
  getter integrationTags : Array(String)
end

enum MeetingType
  MeetingSeries
  ScheduledMeeting
  Meeting
end

enum State
  Active
  Scheduled
  Ready
  Lobby
  InProgress
  Ended
  Missed
  Expired
end

enum ScheduledType
  Meeting
  Webinar
end

struct Telephony
  include JSON::Serializable

  getter accessCode : String
  getter callInNumbers : Array(CallInNumber)
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter coHost : Bool?
  getter links : Array(TelephonyLink)
end

struct CallInNumber
  include JSON::Serializable

  getter label : String
  getter callInNumber : String
  getter tollType : TollType
end

enum TollType
  Toll     # toll
  TollFree # tollfree
end

struct TelephonyLink
  include JSON::Serializable

  getter rel : String
  getter href : String
  getter method : String
end

struct Invites
  include JSON::Serializable

  getter email : String?
  getter displayName : String?
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter coHost : Bool?
end

struct RegistrationRequest
  include JSON::Serializable

  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireFirstName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireLastName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireEmail : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireCompanyName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireCountryRegion : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireWorkPhone : Bool
end

struct RegistrationResponse
  include JSON::Serializable

  @[JSON::Field(converter: Webex::BoolConverter)]
  getter autoAcceptRequest : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireFirstName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireLastName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireEmail : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireJobTitle : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireCompanyName : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireAddress1 : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireAddress2 : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireCity : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireState : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireZipCode : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireCountryRegion : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireWorkPhone : Bool
  @[JSON::Field(converter: Webex::BoolConverter)]
  getter requireFax : Bool
end
