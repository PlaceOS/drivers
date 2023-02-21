require "placeos-driver/spec"
require "placeos-driver/interface/mailer"

class StaffAPI < DriverSpecs::MockDriver
  def get_survey_invites(survey_id : Int64? = nil, sent : Bool? = nil)
    survey_id ||= 1

    unsent_invites = [
      {
        id:        1,
        survey_id: survey_id,
        token:     "QWERTY",
        email:     "user1@spec.test",
        sent:      false,
      },
      {
        id:        2,
        survey_id: survey_id,
        token:     "QWERTY",
        email:     "user1@spec.test",
        sent:      false,
      },
      {
        id:        2,
        survey_id: survey_id,
        token:     "QWERTY",
        email:     "user2@spec.test",
        sent:      false,
      },
    ]

    JSON.parse(unsent_invites.to_json)
  end

  def update_survey_invite(token : String, email : String? = nil, sent : Bool? = nil)
    true
  end
end

class Mailer < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Mailer

  def on_load
    self[:sent] = 0
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  )
    self[:sent] = self[:sent].as_i + 1
  end

  def send_mail(
    to : String | Array(String),
    subject : String,
    message_plaintext : String? = nil,
    message_html : String? = nil,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil
  ) : Bool
    true
  end
end

DriverSpecs.mock_driver "Place::StaffAPI" do
  system({
    StaffAPI: {StaffAPI},
    Mailer:   {Mailer},
  })

  _resp = exec(:send_survey_emails).get
  system(:Mailer_1)[:sent].should eq 2
end
