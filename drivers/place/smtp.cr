require "base64"
require "email"
require "uri"

require "placeos-driver/interface/email"

class Place::Smtp < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Email

  descriptive_name "SMTP Mailer"
  generic_name :Email
  uri_base "https://smtp.host.com"
  description %(sends emails via SMTP)

  default_settings({
    sender:   "support@place.tech",
    host:     "smtp.host",
    port:     587,
    tls_mode: EMail::Client::TLSMode::STARTTLS,
    username: "", # Username/Password for SMTP servers with basic authorization
    password: "",
  })

  private def smtp_client : EMail::Client
    @smtp_client ||= new_smtp_client
  end

  @smtp_client : EMail::Client?

  @sender : String = "PlaceOS"
  @username : String = ""
  @password : String = ""
  @host : String = "smtp.host"
  @port : Int32 = 587
  @tls_mode : EMail::Client::TLSMode = EMail::Client::TLSMode::STARTTLS

  def on_load
    on_update
  end

  def on_update
    @username = setting?(String, :username) || ""
    @password = setting?(String, :password) || ""
    @sender = setting?(String, :sender) || "support@place.tech"
    @host = setting?(String, :host) || "smtp.host"
    @port = setting?(Int32, :port) || 587
    @tls_mode = setting?(EMail::Client::TLSMode, :tls_mode) || EMail::Client::TLSMode::STARTTLS

    @smtp_client = new_smtp_client
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

  def send_mail(
    subject : String,
    to : String | Array(String),
    from : String | Array(String) | Nil = nil,
    message_html : String = "",
    message_plaintext : String = "",
    attachments : Array(Attachment) = [] of Attachment,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String
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

    message.message(message_plaintext) unless message_plaintext.nil?
    message.message_html(message_html) unless message_html.nil?

    # Traverse all attachments
    {resource_attachments, attachments}.map(&.each).each.flatten.each do |attachment|
      # Base64 decode to memory, then attach to email
      attachment_io = IO::Memory.new
      Base64.decode(attachment[:content], attachment_io)

      case attachment
      in Attachment
        message.attach(attachment_io, file_name: attachment[:file_name])
      in ResourceAttachment
        message.message_resource(attachment_io, file_name: attachment[:file_name], cid: attachment[:content_id])
      end
    end

    sent = false
    smtp_client.start do
      sent = send(message)
    end

    sent
  end
end
