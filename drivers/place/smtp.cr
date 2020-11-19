require "qr-code"
require "base64"
require "email"
require "uri"

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
    tls_mode: EMail::Client::TLSMode::STARTTLS.to_s,
    username: "", # Username/Password for SMTP servers with basic authorization
    password: "",

    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
  })

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

  #                   event_name => notify_who => html => template
  alias Templates = Hash(String, Hash(String, Hash(String, String)))

  @templates : Templates = Templates.new

  def on_load
    on_update
  end

  def on_update
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

    @smtp_client = new_smtp_client

    @templates = setting?(Templates, :email_templates) || Templates.new
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

    EMail::Client.new(email_config)
  end

  def generate_svg_qrcode(text : String)
    QRCode.new(text).as_svg
  end

  alias TemplateItems = Hash(String, String | Int64 | Float64 | Bool)

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
    template = @templates[template[0]][template[1]]

    subject = build_template(template["subject"], args)
    text = build_template(template["text"]?, args)
    html = build_template(template["html"]?, args)

    send_mail(to, subject, text || "", html || "", resource_attachments, attachments, cc, bcc, from)
  end

  def build_template(string : String?, args : TemplateItems)
    args.each { |key, value| string = string.gsub("%{#{key}}", value) } if string
    string
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
    to = {to} unless to.is_a?(Array)

    from = {from} unless from.nil? || from.is_a?(Array)
    cc = {cc} unless cc.nil? || cc.is_a?(Array)
    bcc = {bcc} unless bcc.nil? || bcc.is_a?(Array)

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
end
