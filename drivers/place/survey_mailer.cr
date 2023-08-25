require "placeos-driver"
require "placeos-driver/interface/mailer"

class Place::SurveyMailer < PlaceOS::Driver
  descriptive_name "PlaceOS Survey Mailer"
  generic_name :SurveyMailer
  description %(emails survey invites)

  default_settings({
    timezone:       "GMT",
    send_invites:   "*/3 * * * *",
    email_template: "survey",
  })

  accessor staff_api : StaffAPI_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  def on_load
    on_update
  end

  @time_zone : Time::Location = Time::Location.load("GMT")

  @visitor_emails_sent : UInt64 = 0_u64
  @visitor_email_errors : UInt64 = 0_u64

  @email_template : String = "survey"
  @send_invites : String? = nil

  def on_update
    @send_invites = setting?(String, :send_invites).presence
    @email_template = setting?(String, :email_template) || "survey"

    time_zone = setting?(String, :timezone).presence || "GMT"
    @time_zone = Time::Location.load(time_zone)

    schedule.clear
    if invites = @send_invites
      schedule.cron(invites, @time_zone) { send_survey_emails }
    end
  end

  @[Security(Level::Support)]
  def send_survey_emails
    # using #get_survey_invites instead of #get_survey_invites(sent: false)
    # due to `sent <> true` not being equivalent to `sent IS NOT true` in PostgreSQL
    invites = Array(SurveyInvite).from_json staff_api.get_survey_invites.get.to_json
    sent_invites : Hash(String, Array(Int64)) = {} of String => Array(Int64)

    invites.each do |invite|
      next if invite.sent
      begin
        if !(sent_surveys = sent_invites[invite.email]?) || !sent_surveys.includes?(invite.survey_id)
          sent_invites[invite.email] ||= [] of Int64
          sent_invites[invite.email] << invite.survey_id

          mailer.send_template(
            to: invite.email,
            template: {@email_template, "invite"},
            args: {
              email:     invite.email,
              token:     invite.token,
              survey_id: invite.survey_id,
            })
        end

        staff_api.update_survey_invite(invite.token, sent: true)
      rescue error
        logger.warn(exception: error) { "failed to send survey email to #{invite.email}" }
      end
    end
  end

  struct SurveyInvite
    include JSON::Serializable

    property id : Int64
    property survey_id : Int64
    property token : String
    property email : String
    property sent : Bool?
  end
end
