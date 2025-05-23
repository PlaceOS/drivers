require "../place/calendar_common"

class Place::WorkspaceAPI < PlaceOS::Driver
  include Place::CalendarCommon

  # update to trigger build
  descriptive_name "Google Workplace APIs"
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

    # google can handle about 10 requests a second
    rate_limit: 9,

    # defaults to calendar_service_account if not configured
    mailer_from:     "email_or_office_userPrincipalName",
    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
  })
end
