require "../place/calendar_common"

class Microsoft::GraphAPI < PlaceOS::Driver
  include Place::CalendarCommon

  descriptive_name "Microsoft Graph API"
  generic_name :Calendar

  uri_base "https://staff.api.com"

  default_settings({
    calendar_service_account: "service_account@email.address",
    calendar_config:          {
      tenant:          "",
      client_id:       "",
      client_secret:   "",
      conference_type: nil, # This can be set to "teamsForBusiness" to add a Teams link to EVERY created Event
    },

    # defaults to calendar_service_account if not configured
    mailer_from:     "email_or_office_userPrincipalName",
    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
  })
end
