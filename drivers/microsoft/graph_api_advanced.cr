require "../place/calendar_common"

class Microsoft::GraphAPIAdvanced < PlaceOS::Driver
  include Place::CalendarCommon

  descriptive_name "Direct Access to Microsoft Graph API"
  generic_name :MSGraphAPI

  uri_base "https://graph.microsoft.com"

  default_settings({
    calendar_config: {
      tenant:        "",
      client_id:     "",
      client_secret: "",
    },
  })
end
