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
  @ssl_verify_ignore : Bool = false

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
    @ssl_verify_ignore = setting?(Bool, :ssl_verify_ignore) || false

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
end
