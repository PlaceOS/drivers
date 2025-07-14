require "json"

# Humly Control Panel API Models
# Documentation: https://raw.githubusercontent.com/CertusOp/humly-control-panel-rest-api/refs/heads/master/README.md

module Humly
  module RestApi
  # Base response structures
  struct BaseResponse
    include JSON::Serializable

    getter status : String
    getter message : String?
  end

  struct PaginationInfo
    include JSON::Serializable

    getter first : Bool
    getter last : Bool
    getter size : Int32
    getter totalElements : Int32
    getter totalPages : Int32
    getter number : Int32
    getter numberOfElements : Int32
  end

  struct SortInfo
    include JSON::Serializable

    getter property : String
    getter direction : String
  end

  struct ApiResponse(T)
    include JSON::Serializable

    getter status : String
    getter data : T?
    getter page : PaginationInfo?
    getter sort : Array(SortInfo)?
    getter message : String?
  end

  # Authentication models
  struct LoginResponse
    include JSON::Serializable

    getter authToken : String
    getter userId : String
  end

  struct LogoutResponse
    include JSON::Serializable

    getter message : String
  end

  # Client Group models
  struct ClientGroup
    include JSON::Serializable

    getter _id : String
    getter groupName : String
    getter groupToken : String
  end

  # User models
  struct UserProfile
    include JSON::Serializable

    getter clientGroup : String
    getter description : String
    getter name : String
    getter type : String
    getter groupToken : String?
    getter originalToken : String?
    getter pin : String?
    getter rfid : String?
  end

  struct UserAuthentication
    include JSON::Serializable

    getter pin : String
    getter rfid : String
    getter originalToken : String?
    getter groupToken : String
  end

  struct User
    include JSON::Serializable

    getter _id : String
    getter username : String
    getter createdAt : String
    getter profile : UserProfile
    getter authentication : UserAuthentication?
    getter userAgentOnLastLogin : String?
  end

  # Display Settings models
  struct DisplaySettings
    include JSON::Serializable

    getter organizer : Bool
    getter subject : Bool?
    getter participants : Bool?
  end

  struct BookingSettings
    include JSON::Serializable

    getter enabled : Bool
    getter auth : Bool
  end

  struct RoomSettings
    include JSON::Serializable

    getter emailReminder : Bool
    getter timeZone : String
    getter timeZoneCode : String
    getter allowGuestUsers : Bool
    getter confirmDuration : String?
    getter displaySettings : DisplaySettings
    getter bookMeetingSettings : BookingSettings
    getter bookFutureMeetingSettings : BookingSettings
    getter endOngoingMeetingSettings : BookingSettings
    getter extendOngoingMeetingSettings : BookingSettings?
    getter showCurrentBookingSettings : BookingSettings?
    getter showBookingDescriptionSettings : BookingSettings?
    getter showBookingInviteesSettings : BookingSettings?
    getter showBookingOrganizerSettings : BookingSettings?
    getter showBookingLocationSettings : BookingSettings?
    getter showBookingUidSettings : BookingSettings?
    getter showBookingTitleSettings : BookingSettings?
  end

  # Equipment models
  struct Equipment
    include JSON::Serializable

    getter lights : Bool?
    getter projector : Bool?
    getter computer : Bool?
    getter teleConference : Bool?
    getter wifi : Bool?
    getter whiteboard : Bool?
    getter videoConference : Bool?
    getter display : Bool?
    getter minto : Bool?
    getter ac : Bool?
    getter information : String?
  end

  struct CustomEquipment
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter isChecked : Bool
  end

  struct EquipmentInfo
    include JSON::Serializable

    getter equipment : Equipment
    getter customEquipment : Array(CustomEquipment)
    getter message : String?
  end

  # Room models
  struct Room
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter mail : String
    getter address : String
    getter id : String
    getter numberOfSeats : Int32
    getter alias : String
    getter isActive : Bool
    getter isDeleted : Bool?
    getter bookingSystemSyncSupported : Bool
    getter resourceType : String
    getter bookingUri : String?
    getter settings : RoomSettings
    getter structureId : String?
    getter equipment : Equipment?
    getter customEquipment : Array(CustomEquipment)?
  end

  struct RoomAvailability
    include JSON::Serializable

    getter fullMatchArray : Array(Room)
    getter partialMatchArray : Array(Room)?
  end

  # Desk models (similar to Room but with different resource type)
  struct Desk
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter mail : String
    getter address : String
    getter id : String
    getter numberOfSeats : Int32
    getter alias : String
    getter isActive : Bool
    getter bookingSystemSyncSupported : Bool
    getter resourceType : String
    getter bookingUri : String?
    getter settings : RoomSettings
    getter structureId : String?
  end

  # Booking models
  struct BookingCreatedBy
    include JSON::Serializable

    getter name : String
    getter mail : String
    getter createdAt : String?
    getter userId : String?
    getter isGuestUser : Bool?
  end

  struct BookingDetail
    include JSON::Serializable

    getter startDate : String
    getter endDate : String
    getter location : String
    getter startTime : String
    getter endTime : String
    getter onlyDate : String
    getter dateForStatistics : String
    getter createdBy : BookingCreatedBy
    getter dateCreated : String?
    getter endType : String?
    getter confirmed : Bool
    getter subject : String
    getter body : String?
    getter equipment : Equipment?
    getter freeBusyStatus : String?
    getter showConfirm : Bool
    getter sensitivity : String?
    getter numberOfExpectedReminderResponses : Int32?
    getter numberOfReceivedReminderResponses : Int32?
    getter sendReminderEmailCheck : Bool?
    getter sendReminderEmailCheckTime : String?
    getter numberOfExpectedCancellationResponses : Int32?
    getter numberOfReceivedCancellationResponses : Int32?
    getter sendCancellationEmailCheck : Bool?
    getter sendCancellationEmailCheckTime : String?
    getter reminderEmailSent : Bool?
    getter cancellationEmailSent : Bool?
    getter isCancelled : Bool?
    getter cancelledAt : String?
    getter cancelledBy : BookingCreatedBy?
    getter isExtended : Bool?
    getter extendedAt : String?
    getter extendedBy : BookingCreatedBy?
    getter isPrivate : Bool?
    getter participants : Array(String)?
    getter organizer : String?
    getter recurringId : String?
    getter instanceId : String?
    getter isRecurring : Bool?
    getter recurrencePattern : String?
    getter recurrenceEndDate : String?
    getter attendees : Array(String)?
  end

  struct Booking
    include JSON::Serializable

    getter _id : String
    getter id : String
    getter changeKey : String
    getter source : String
    getter eventIdentifier : String
    getter booking : BookingDetail
    getter resourceId : String?
  end

  # Structure models
  struct Floor
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter level : Int32
    getter parent : String
  end

  struct Building
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter level : Int32
    getter parent : String
    getter floors : Array(Floor)
  end

  struct City
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter level : Int32
    getter parent : String
    getter buildings : Array(Building)
  end

  struct Country
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter level : Int32
    getter parent : Int32
    getter cities : Array(City)
  end

  # Device models
  struct Device
    include JSON::Serializable

    getter _id : String
    getter resourceId : String
    getter macAddress : String
    getter isRebootable : Bool
    getter wentOfflineAt : String?
    getter lastRebootTime : String?
    getter lastConnectionTime : String?
    getter macAddressWifi : String?
    getter ipAddress : String?
    getter secondIpAddress : String?
    getter interfaceActive : String?
    getter serverIpAddress : String?
    getter firmwareVersion : String?
    getter vncActive : Bool?
    getter serialId : String?
    getter isPairingKeyApproved : Bool?
    getter deviceType : String?
    getter sleepFrom : String?
    getter wakeAt : String?
    getter status : String?
    getter upgradeStatus : String?
    getter vncConnectionUrl : String?
    getter name : String?
    getter location : String?
    getter model : String?
    getter manufacturer : String?
    getter description : String?
    getter isOnline : Bool?
    getter batteryLevel : Int32?
    getter lastSeenAt : String?
    getter capabilities : Array(String)?
    getter version : String?
    getter heartbeatInterval : Int32?
    getter lastHeartbeat : String?
  end

  # Sensor models
  struct SensorReading
    include JSON::Serializable

    getter eventId : String
    getter value : Float32
    getter updateTime : String
  end

  struct Sensor
    include JSON::Serializable

    getter _id : String
    getter type : String
    getter externalId : String
    getter status : String
    getter distributor : String
    getter name : String
    getter description : String?
    getter minRange : Float32?
    getter maxRange : Float32?
    getter displayUnitCode : String?
    getter displayUnit : String?
    getter resourceIds : Array(String)
    getter readings : Array(SensorReading)?
    getter lastReading : SensorReading?
    getter calibrationOffset : Float32?
    getter calibrationMultiplier : Float32?
    getter alertThresholdMin : Float32?
    getter alertThresholdMax : Float32?
    getter isAlertEnabled : Bool?
    getter location : String?
    getter installationDate : String?
    getter lastMaintenanceDate : String?
    getter maintenanceInterval : Int32?
    getter batteryLevel : Int32?
    getter signalStrength : Int32?
    getter firmware : String?
    getter model : String?
    getter serialNumber : String?
    getter manufacturer : String?
  end

  struct SensorReadingData
    include JSON::Serializable

    getter _id : String
    getter sensorId : String
    getter externalId : String
    getter date : String
    getter type : String
    getter displayUnit : String
    getter displayUnitCode : String
    getter maxRange : Float32?
    getter minRange : Float32?
    getter readings : Array(SensorReading)
    getter resourceIds : Array(String)
    getter status : String
    getter location : String?
    getter averageValue : Float32?
    getter minValue : Float32?
    getter maxValue : Float32?
    getter readingCount : Int32?
  end

  # Visitor Screen models
  struct VisitorScreen
    include JSON::Serializable

    getter _id : String
    getter name : String
    getter resourceId : String
    getter structureId : String
    getter isActive : Bool
    getter settings : Hash(String, JSON::Any)
    getter displaySettings : DisplaySettings?
    getter location : String?
    getter description : String?
    getter orientation : String?
    getter screenSize : String?
    getter resolution : String?
    getter brightness : Int32?
    getter volume : Int32?
    getter lastSeen : String?
    getter status : String?
    getter ipAddress : String?
    getter macAddress : String?
    getter version : String?
    getter model : String?
    getter manufacturer : String?
    getter serialNumber : String?
  end

  # Generic delete response
  struct DeleteResponse
    include JSON::Serializable

    getter message : String
  end

  # Error response
  struct ErrorResponse
    include JSON::Serializable

    getter status : String
    getter message : String
  end
  end
end
