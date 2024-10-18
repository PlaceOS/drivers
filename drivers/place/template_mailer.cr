# require "qr-code"
# require "qr-code/export/png"
# require "base64"
# require "email"
# require "uri"
require "placeos-driver"
require "placeos-driver/interface/mailer"

class Place::TemplateMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Mailer

  descriptive_name "Template Mailer"
  generic_name :TemplateMailer
  description %(uses metadata templates to send emails via the SMTP mailer)

  default_settings({
    seperator: ".",
  })

  accessor staff_api : StaffAPI_1

  getter org_zone_ids : Array(String) { get_zone_ids?("org").not_nil! }
  getter building_zone_ids : Array(String) { get_zone_ids?("building").not_nil! }

  def mailer
    system.implementing(Interface::Mailer)[1]
  end

  @seperator : String = "."

  def template_fields : Hash(String, TemplateFields)
    {
    "visitor_invited#{@seperator}visitor" => TemplateFields.new(
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
    "visitor_invited#{@seperator}event" => TemplateFields.new(
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
    "visitor_invited#{@seperator}booking" => TemplateFields.new(
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
    "visitor_invited#{@seperator}notify_checkin" => TemplateFields.new(
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
    "visitor_invited#{@seperator}group_event" => TemplateFields.new(
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
    "bookings#{@seperator}booked_by_notify" => TemplateFields.new(
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
    "bookings#{@seperator}booking_notify" => TemplateFields.new(
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
    "bookings#{@seperator}cancelled" => TemplateFields.new(
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
    "auto_release#{@seperator}auto_release" => TemplateFields.new(
      name: "Auto Release",
      fields: [
        TemplateField.new(name: "booking_id", description: "The ID of the booking"),
        TemplateField.new(name: "user_email", description: "The email of the user"),
        TemplateField.new(name: "user_name", description: "The name of the user"),
        TemplateField.new(name: "booking_start", description: "The start time of the booking"),
        TemplateField.new(name: "booking_end", description: "The end time of the booking"),
      ],
    ),
    "survey#{@seperator}invite" => TemplateFields.new(
      name: "Survey Invite",
      fields: [
        TemplateField.new(name: "email", description: "The email of the recipient"),
        TemplateField.new(name: "token", description: "The token for the survey"),
        TemplateField.new(name: "survey_id", description: "The ID of the survey"),
      ],
    ),
  }
end

  def on_load
    on_update
  end

  def on_update
    @seperator = setting?(String, :seperator) || "."

    org_zone_ids.each do |zone_id|
      update_email_template_fields(zone_id)
    end
  end

  def get_zone_ids?(tag : String) : Array(String)?
    staff_api.zones(tags: tag).get.as_a.map(&.[]("id").as_s)
  rescue error
    logger.warn(exception: error) { "unable to determine #{tag} zone ids" }
    nil
  end

  def get_email_template_fields?(zone_id : String) : Hash(String, TemplateFields)?
    metadata = Metadata.from_json staff_api.metadata(zone_id, "email_template_fields").get["email_template_fields"].to_json
    Hash(String, TemplateFields).from_json metadata.details.to_json
  rescue error
    logger.warn(exception: error) { "unable to get email template fields from zone #{zone_id} metadata" }
    nil
  end

  def update_email_template_fields(zone_id : String)
    staff_api.write_metadata(id: zone_id, key: "email_template_fields", payload: template_fields, description: "Available fields for use in email templates").get
  end

  def get_templates?(zone_id : String) : Array(Template)?
    metadata = Metadata.from_json staff_api.metadata(zone_id, "email_templates").get["email_templates"].to_json
    metadata.details.as_a.map { |template| Template.from_json template.to_json }
  rescue error
    logger.warn(exception: error) { "unable to get email templates from zone #{zone_id} metadata" }
    nil
  end

  #   def fetch_templates(zone_ids : Array(String))
  #     building_id = (zone_ids & @building_templates.keys).first
  #     org_id = (zone_ids & @org_templates.keys).first
  #   end

  # def get_templates : Templates
  #   # fetch templates
  #   templates = get_templates_from_settings? || Templates.new
  #   org_templates = templates_to_mailer(get_templates_from_metadata?(org_zone_id) || [] of Template)
  #   building_templates = templates_to_mailer(get_templates_from_metadata?(building_zone_id) || [] of Template)

  #   # merge templates (settings < org < building)
  #   templates.merge(org_templates).merge(building_templates)
  # end

  # def get_templates_from_settings? : Templates?
  #   setting?(Templates, :email_templates)
  # end

  # def get_templates_from_metadata?(zone_id : String) : Array(Template)?
  #   metadata = Metadata.from_json staff_api.metadata(zone_id, "email_templates").get["email_templates"].to_json
  #   metadata.details.as_a.map { |template| Template.from_json template.to_json }
  # rescue error
  #   logger.warn(exception: error) { "unable to get email templates from zone #{zone_id} metadata" }
  #   nil
  # end

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
  )
    mailer.send_mail(to, subject, message_plaintext, message_html, resource_attachments, attachments, cc, bcc, from)
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
    # if zone_ids = args["zone_ids"]? && zone_ids.is_a?(Array(String))
    #     templates = fetch_templates(zone_ids)
    #     templates ["#{template[0]}#{@seperator}#{template[1]}"]]
    # end

    #   TODO:
    #  - find template from metadata
    #  - if no template was found, then just proxy send_template on the mailer

    # template = begin
    #   @templates[template[0]][template[1]]
    # rescue
    #   logger.warn { "no template found with: #{template}" }
    #   return
    # end

    # subject = build_template(template["subject"], args)
    # text = build_template(template["text"]?, args)
    # html = build_template(template["html"]?, args)

    # mailer.send_mail(to, subject, text || "", html || "", resource_attachments, attachments, cc, bcc, from)

    mailer.send_template(to, template, args, resource_attachments, attachments, cc, bcc, from)
  end

  alias Template = Hash(String, String)

  # # convert metadata templates to mailer templates
  # def templates_to_mailer(templates : Array(Template)) : Templates
  #   mailer_templates = Templates.new
  #   templates.each do |template|
  #     trigger = template["trigger"].split(".")
  #     mailer_templates[trigger[0]] ||= {} of String => Hash(String, String)
  #     mailer_templates[trigger[0]][trigger[1]] = template.to_h
  #   end
  #   mailer_templates
  # end

  # # convert mailer templates to metadata templates
  # def templates_to_metadata(templates : Templates) : Array(Template)
  #   templates.flat_map do |event_name, notify_who|
  #     notify_who.map do |notify, template|
  #       template["trigger"] = "#{event_name}.#{notify}"
  #       template["zone_id"] = org_zone_id unless template["zone_id"]?
  #       template["created_at"] = Time.utc.to_unix.to_s unless template["created_at"]?
  #       template["updated_at"] = Time.utc.to_unix.to_s unless template["updated_at"]?
  #       template["id"] = %(template-#{Digest::MD5.hexdigest("#{template["trigger"]}#{template["created_at"]}")}) unless template["id"]?
  #       template
  #     end
  #   end
  # end

  struct Metadata
    include JSON::Serializable

    property name : String
    property description : String = ""
    property details : JSON::Any
    property parent_id : String
    property schema_id : String? = nil
    property editors : Set(String) = Set(String).new
    property modified_by_id : String? = nil
  end

  record TemplateFields, name : String, fields : Array(TemplateField) do
    include JSON::Serializable
  end

  record TemplateField, name : String, description : String do
    include JSON::Serializable
  end
end

# def mailer
#     system.implementing(Interface::Mailer)[1]
#   end

# accessor mailers, implementing: Interface::Mailer

# template mailer sits in front of smtp mailer
# and proxies the mailer interface
# it also overrides the send_template method
# to use metadata templates instead
# if no metadata template is found then it just proxies the smtp mailer
#
