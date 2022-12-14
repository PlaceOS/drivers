require "placeos-driver"
require "placeos-driver/interface/mailer"

require "uuid"
require "oauth2"

class Place::SurveyMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Survey Mailer"
  generic_name :SurveyMailer
  description %(emails survey invites)

  default_settings({
    timezone:            "GMT",
    send_survey_invites: "*/3 * * * *",
    email_template:      "survey",
  })

  accessor mailer : Mailer_1, implementing: PlaceOS::Driver::Interface::Mailer
  accessor staff_api : StaffAPI_1

  def on_load
    on_update
  end

  @time_zone : Time::Location = Time::Location.load("GMT")

  @visitor_emails_sent : UInt64 = 0_u64
  @visitor_email_errors : UInt64 = 0_u64

  @email_template : String = "survey"
  @schedule : String? = nil

  def on_update
    @send_survey_invites = setting?(String, :send_survey_invites).presence
    @email_template = setting?(String, :email_template) || "survey"

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    schedule.clear
    if survey_invites = @send_survey_invites
      schedule.cron(survey_invites, @time_zone) { send_survey_emails }
    end
  end

  @[Security(Level::Support)]
  def send_survey_emails
    invites = Array(SurveyInvite).from_json staff_api.get_survey_invites(sent: false).get.to_json

    invites.each do |invite|
      begin
        mailer.send_template(
          to: invite.email,
          template: {email_template, "invite"},
          args: {
            email: invite.email,
            token: invite.token,
          })
      rescue error
        logger.warn(exception: error) { "failed to send survey email to #{invite.email}" }
      end
    end
  end

  struct SurveyInvite
    include JSON::Serializable

    property id : Int64
    property token : String
    property email : String
    property sent : Bool
    property created_at : Time
    property updated_at : Time
  end
end
