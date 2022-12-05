require "./calendar_common"

class Place::Calendar < PlaceOS::Driver
  include Place::CalendarCommon

  descriptive_name "PlaceOS Calendar"
  generic_name :Calendar

  uri_base "https://staff.app.api.com"

  default_settings({
    calendar_service_account: "service_account@email.address",
    calendar_config:          {
      scopes:      ["https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/admin.directory.user.readonly"],
      domain:      "primary.domain.com",
      sub:         "default.service.account@google.com",
      issuer:      "placeos@organisation.iam.gserviceaccount.com",
      signing_key: "PEM encoded private key",
    },
    calendar_config_office: {
      _note_:          "rename to 'calendar_config' for use",
      tenant:          "",
      client_id:       "",
      client_secret:   "",
      conference_type: nil, # This can be set to "teamsForBusiness" to add a Teams link to EVERY created Event
    },
    rate_limit: 5,

    # defaults to calendar_service_account if not configured
    mailer_from:     "email_or_office_userPrincipalName",
    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
  })
end
