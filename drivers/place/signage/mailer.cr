require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"

class Place::Signage::Mailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Signage Mailer"
  generic_name :SignageMailer
  description %(processes digital signage email queue)

  accessor staff_api : StaffAPI_1

  protected def mailer
    system.implementing(Interface::Mailer)[0]
  end

  default_settings({
    # time in minutes
    poll_rate: 10,

    # authority to monitor
    authority_id: "authority-XX7",
  })

  @poll_rate : Time::Span = 10.minutes
  @authority_id : String? = nil

  struct SignageMailNotice
    include JSON::Serializable

    property id : String
    property service : String
    property reference : String
  end

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 20).minutes
    @authority_id = auth_id = setting?(String, :authority_id)

    subscriptions.clear
    schedule.clear
    schedule.every(@poll_rate) { process_signage_mail }

    if auth_id
      monitor("#{auth_id}/pending_mail/new") do |_subscription, payload|
        logger.debug { "received new mail event: #{payload}" }
        new_mail SignageMailNotice.from_json(payload)
      end
    end
  end

  # ===================================
  # Monitoring desk bookings
  # ===================================

  protected def new_mail(event : SignageMailNotice)
    process_signage_mail
  end

  # ===================================
  # Background Sync
  # ===================================

  @sync_mutex : Mutex = Mutex.new
  @sync_requests : UInt32 = 0_u32
  @syncing : Bool = false

  def process_signage_mail
    @sync_requests += 1
    return "already processing" if @syncing

    @sync_mutex.synchronize do
      begin
        @syncing = true
        @sync_requests = 0
        query_signage_mail
      ensure
        @syncing = false
      end
    end

    spawn { process_signage_mail } if @sync_requests > 0
    "parking allocated"
  end

  struct PendingMail
    include JSON::Serializable

    getter id : String
    getter send_to : Array(String)
    getter cc : Array(String)
    getter bcc : Array(String)
    getter template : Tuple(String, String)
    getter args : Hash(String, JSON::Any)
  end

  protected def query_signage_mail
    Array(PendingMail).from_json(
      staff_api.email_query(source_service: "signage", unsent_only: true).get_json
    ).each do |email|
      approval_email email
    end
  end

  protected def approval_email(email : PendingMail)
    mailer.send_template(
      to: email.send_to,
      template: email.template,
      args: email.args,
      cc: email.cc,
      bcc: email.bcc,
    ).get_json
    staff_api.email_sent(email.id).get_json
  rescue error
    logger.error(exception: error) { "failed to send approval email" }
  end

  # ===================================
  # Mailer templates
  # ===================================

  def template_fields : Array(TemplateFields)
    common_fields = [
      {name: "group_name", description: "Name of the signage group"},
      {name: "group_id", description: "The signage group id"},
      {name: "playlist_name", description: "The playlist name"},
      {name: "playlist_id", description: "The playlist id"},
      {name: "user_name", description: "The name of the user requesting approval"},
      {name: "user_email", description: "The email of the user requesting approval"},
      {name: "message", description: "A message from the user"},
    ]

    [
      TemplateFields.new(
        trigger: {"signage", "request_playlist_approval"},
        name: "Playlist Approval Request",
        description: "Provides details of a paylist in need of approval",
        fields: common_fields,
      ),
    ]
  end
end
