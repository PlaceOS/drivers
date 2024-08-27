require "qr-code"
require "qr-code/export/png"
require "base64"
require "email"
require "uri"
require "placeos-driver"
require "placeos-driver/interface/mailer"

class Place::Smtp < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Mailer

  descriptive_name "SMTP Mailer"
  generic_name :Mailer
  uri_base "https://smtp.host.com"
  description %(sends emails via SMTP)

  default_settings({
    sender: "support@place.tech",
    # host:     "smtp.host",
    # port:     587,
    tls_mode:          EMail::Client::TLSMode::STARTTLS.to_s,
    ssl_verify_ignore: false,
    username:          "", # Username/Password for SMTP servers with basic authorization
    password:          "",
  })

  accessor staff_api : StaffAPI_1

  getter org_zone_id : String { get_org_zone_id?.not_nil! }

  private def smtp_client : EMail::Client
    @smtp_client ||= new_smtp_client
  end

  @smtp_client : EMail::Client?

  @sender : String = "support@place.tech"
  @username : String = ""
  @password : String = ""
  @host : String = "smtp.host"
  @port : Int32 = 587
  @tls_mode : EMail::Client::TLSMode = EMail::Client::TLSMode::STARTTLS
  @send_lock : Mutex = Mutex.new
  @ssl_verify_ignore : Bool = false

  @template_fields : Hash(String, TemplateFields) = {
    "visitor_invited": TemplateFields.new(
      name: "Visitor Invited",
      fields: [
        TemplateField.new(name: "visitor_email", description: "The email of the visitor"),
        TemplateField.new(name: "visitor_name", description: "The name of the visitor"),
        TemplateField.new(name: "host_name", description: "The name of the host"),
        TemplateField.new(name: "host_email", description: "The email of the host"),
        TemplateField.new(name: "room_name", description: "The name of the room"),
        TemplateField.new(name: "building_name", description: "The name of the building"),
        TemplateField.new(name: "event_title", description: "The title of the event"),
        TemplateField.new(name: "event_start", description: "The start time of the event"),
        TemplateField.new(name: "event_date", description: "The date of the event"),
        TemplateField.new(name: "event_time", description: "The time of the event"),
        TemplateField.new(name: "network_username", description: "The network username"),
        TemplateField.new(name: "network_password", description: "The network password"),
      ],
    ),
    "bookings": TemplateFields.new(
      name: "Bookings",
      fields: [
        TemplateField.new(name: "booking_id", description: "The ID of the booking"),
        TemplateField.new(name: "start_time", description: "The start time of the booking"),
        TemplateField.new(name: "start_date", description: "The start date of the booking"),
        TemplateField.new(name: "start_datetime", description: "The start date and time of the booking"),
        TemplateField.new(name: "end_time", description: "The end time of the booking"),
        TemplateField.new(name: "end_date", description: "The end date of the booking"),
        TemplateField.new(name: "end_datetime", description: "The end date and time of the booking"),
        TemplateField.new(name: "starting_unix", description: "The starting time of the booking in Unix timestamp"),
        TemplateField.new(name: "asset_id", description: "The ID of the asset"),
        TemplateField.new(name: "user_id", description: "The ID of the user"),
        TemplateField.new(name: "user_email", description: "The email of the user"),
        TemplateField.new(name: "user_name", description: "The name of the user"),
        TemplateField.new(name: "reason", description: "The reason for the booking"),
        TemplateField.new(name: "level_zone", description: "The level zone of the booking"),
        TemplateField.new(name: "building_zone", description: "The building zone of the booking"),
        TemplateField.new(name: "building_name", description: "The name of the building"),
        TemplateField.new(name: "approver_name", description: "The name of the approver"),
        TemplateField.new(name: "approver_email", description: "The email of the approver"),
        TemplateField.new(name: "booked_by_name", description: "The name of the person who booked"),
        TemplateField.new(name: "booked_by_email", description: "The email of the person who booked"),
        TemplateField.new(name: "attachment_name", description: "The name of the attachment"),
        TemplateField.new(name: "attachment_url", description: "The URL of the attachment"),
        TemplateField.new(name: "network_username", description: "The network username"),
        TemplateField.new(name: "network_password", description: "The network password"),
      ],
    ),
    "auto_release": TemplateFields.new(
      name: "Auto Release",
      fields: [
        TemplateField.new(name: "booking_id", description: "The ID of the booking"),
        TemplateField.new(name: "user_email", description: "The email of the user"),
        TemplateField.new(name: "user_name", description: "The name of the user"),
        TemplateField.new(name: "booking_start", description: "The start time of the booking"),
        TemplateField.new(name: "booking_end", description: "The end time of the booking"),
      ],
    ),
    "survey": TemplateFields.new(
      name: "Survey Invite",
      fields: [
        TemplateField.new(name: "email", description: "The email of the recipient"),
        TemplateField.new(name: "token", description: "The token for the survey"),
        TemplateField.new(name: "survey_id", description: "The ID of the survey"),
      ],
    ),

  }

  def on_load
    on_update
  end

  def on_update
    @org_zone_id = nil

    defaults = URI.parse(config.uri.not_nil!)
    tls_mode = if scheme = defaults.scheme
                 scheme.ends_with?('s') ? EMail::Client::TLSMode::SMTPS : EMail::Client::TLSMode::STARTTLS
               else
                 EMail::Client::TLSMode::STARTTLS
               end
    port = defaults.port || 587
    host = defaults.host || "smtp.host"

    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
    @sender = setting?(String, :sender) || "support@place.tech"
    @host = setting?(String, :host) || host
    @port = setting?(Int32, :port) || port
    @tls_mode = setting?(EMail::Client::TLSMode, :tls_mode) || tls_mode
    @ssl_verify_ignore = setting?(Bool, :ssl_verify_ignore) || false

    @smtp_client = new_smtp_client

    update_email_template_fields(@template_fields)

    migrate_email_templates
    @templates = get_email_templates? || Templates.new
    schedule.every(2.minute) { @templates = get_email_templates? || Templates.new }
  end

  # Finds the org zone id for the current location services object
  def get_org_zone_id? : String?
    zone_ids = staff_api.zones(tags: "org").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine org zone id" }
    nil
  end

  def get_email_templates? : Templates?
    Templates.from_json staff_api.metadata(org_zone_id, "email_templates").get.to_json
  rescue error
    logger.warn(exception: error) { "unable to get email templates from org metadata" }
    nil
  end

  # Migrate email templates from settings to metadata
  def migrate_email_templates
    return if get_email_templates?

    old_templates = setting?(Templates, :email_templates)
    default_templates = {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}}
    email_templates = old_templates ? old_templates : default_templates
    staff_api.write_metadata(id: org_zone_id, key: "email_templates", payload: email_templates, description: "Email templates for the SMTP driver").get
  end

  def get_email_template_fields? : Hash(String, TemplateFields)?
    metadata = Metadata.from_json staff_api.metadata(org_zone_id, "email_template_fields").get["email_template_fields"].to_json
    Hash(String, TemplateFields).from_json metadata.details.to_json
  rescue error
    logger.warn(exception: error) { "unable to get email template fields from org metadata" }
    nil
  end

  def update_email_template_fields(template_fields : Hash(String, TemplateFields))
    staff_api.write_metadata(id: org_zone_id, key: "email_template_fields", payload: template_fields, description: "Available fields for use in email templates").get
  end

  # Create and configure an SMTP client
  private def new_smtp_client
    email_config = EMail::Client::Config.new(@host, @port)
    email_config.log = logger
    email_config.client_name = "PlaceOS"

    unless @username.empty? || @password.empty?
      email_config.use_auth(@username, @password)
    end

    email_config.use_tls(@tls_mode)
    email_config.tls_context.verify_mode = OpenSSL::SSL::VerifyMode::None if @ssl_verify_ignore

    EMail::Client.new(email_config)
  end

  def generate_svg_qrcode(text : String) : String
    QRCode.new(text).as_svg
  end

  def generate_png_qrcode(text : String, size : Int32 = 128) : String
    Base64.strict_encode QRCode.new(text).as_png(size: size)
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
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil
  ) : Bool
    to = {to} unless to.is_a?(Array)

    from = {from} unless from.nil? || from.is_a?(Array)
    cc = {cc} unless cc.nil? || cc.is_a?(Array)
    bcc = {bcc} unless bcc.nil? || bcc.is_a?(Array)
    reply_to = {reply_to} unless reply_to.nil? || reply_to.is_a?(Array)

    message = EMail::Message.new

    message.subject(subject)

    message.sender(@sender)

    if from.nil? || from.empty?
      message.from(@sender)
    else
      from.each { |_from| message.from(_from) }
    end

    to.each { |_to| message.to(_to) }
    bcc.each { |_bcc| message.bcc(_bcc) }
    cc.each { |_cc| message.cc(_cc) }

    if reply_to
      reply_to.each { |_reply| message.reply_to(_reply) }
    end

    message.message(message_plaintext.as(String)) unless message_plaintext.presence.nil?
    message.message_html(message_html.as(String)) unless message_html.presence.nil?

    # Traverse all attachments
    {resource_attachments, attachments}.map(&.each).each.flatten.each do |attachment|
      # Base64 decode to memory, then attach to email
      attachment_io = IO::Memory.new
      Base64.decode(attachment[:content], attachment_io)
      attachment_io.rewind

      case attachment
      in Attachment
        message.attach(io: attachment_io, file_name: attachment[:file_name])
      in ResourceAttachment
        message.message_resource(io: attachment_io, file_name: attachment[:file_name], cid: attachment[:content_id])
      end
    end

    sent = false

    # Ensure only a single send at a time
    @send_lock.synchronize do
      smtp_client.start do
        sent = send(message)
      end
    end

    sent
  end

  record TemplateFields, name : String, fields : Array(TemplateField) do
    include JSON::Serializable
  end

  record TemplateField, name : String, description : String do
    include JSON::Serializable
  end
end
