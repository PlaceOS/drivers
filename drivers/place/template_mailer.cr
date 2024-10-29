require "placeos-driver"
require "placeos-driver/interface/mailer"

class Place::TemplateMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Mailer

  descriptive_name "Template Mailer"
  generic_name :Mailer
  description %(uses metadata templates to send emails via the SMTP mailer)

  default_settings({
    cache_timeout: 300, # timeout for the template cache
  })

  accessor staff_api : StaffAPI_1

  getter org_zone_ids : Array(String) { get_zone_ids?("org").not_nil! }
  getter region_zone_ids : Array(String) { get_zone_ids?("region").not_nil! }
  getter building_zone_ids : Array(String) { get_zone_ids?("building").not_nil! }
  getter level_zone_ids : Array(String) { get_zone_ids?("level").not_nil! }

  def mailer
    system.implementing(Interface::Mailer)[1]
  end

  SEPERATOR = "."

  @template_cache : TemplateCache = TemplateCache.new
  @cache_timeout : Int64 = 300

  def on_load
    on_update
  end

  def on_update
    @cache_timeout = setting?(Int64, :cache_timeout) || 300_i64

    org_zone_ids.each do |zone_id|
      update_template_fields(zone_id)
    end
  end

  def get_zone_ids?(tag : String) : Array(String)?
    staff_api.zones(tags: tag).get.as_a.map(&.[]("id").as_s)
  rescue error
    logger.warn(exception: error) { "unable to determine #{tag} zone ids" }
    nil
  end

  def get_template_fields?(zone_id : String) : Hash(String, TemplateFields)?
    metadata = Metadata.from_json staff_api.metadata(zone_id, "email_template_fields").get["email_template_fields"].to_json
    Hash(String, TemplateFields).from_json metadata.details.to_json
  rescue error
    logger.warn(exception: error) { "unable to get email template fields from zone #{zone_id} metadata" }
    nil
  end

  def update_template_fields(zone_id : String)
    staff_api.write_metadata(id: zone_id, key: "email_template_fields", payload: TEMPLATE_FIELDS, description: "Available fields for use in email templates").get
  end

  # fetch templates from cache or metadata
  def fetch_templates(zone_id : String) : Array(Template)
    if (cache = @template_cache[zone_id]?) && cache[0] > Time.utc.to_unix
      cache[1]
    else
      templates = get_templates?(zone_id) || [] of Template
      @template_cache[zone_id] = {Time.utc.to_unix + @cache_timeout, templates}
      templates
    end
  end

  def template_cache
    @template_cache
  end

  def clear_template_cache(zone_id : String? = nil)
    if zone_id && !zone_id.blank?
      @template_cache.delete(zone_id)
    else
      @template_cache = TemplateCache.new
    end
  end

  # get templates from metadata
  def get_templates?(zone_id : String) : Array(Template)?
    metadata = Metadata.from_json staff_api.metadata(zone_id, "email_templates").get["email_templates"].to_json
    metadata.details.as_a.map { |template| Template.from_json template.to_json }
  rescue error
    logger.warn(exception: error) { "unable to get email templates from zone #{zone_id} metadata" }
    nil
  end

  def find_template?(template : String, zone_ids : Array(String)) : Template?
    org_id = (zone_ids & org_zone_ids).first
    region_id = (zone_ids & region_zone_ids).first
    building_id = (zone_ids & building_zone_ids).first
    level_id = (zone_ids & level_zone_ids).first

    org_templates = fetch_templates(org_id)
    region_templates = fetch_templates(region_id)
    building_templates = fetch_templates(building_id)
    level_templates = fetch_templates(level_id)

    # find the requested template
    # order of precedence: level, building, region, org
    level_templates.find { |t| t["trigger"] == template } ||
      building_templates.find { |t| t["trigger"] == template } ||
      region_templates.find { |t| t["trigger"] == template } ||
      org_templates.find { |t| t["trigger"] == template } ||
      nil
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
  )
    mailer.send_mail(to, subject, message_plaintext, message_html, resource_attachments, attachments, cc, bcc, from, reply_to)
  end

  def send_template(
    to : String | Array(String),
    template : Tuple(String, String),
    args : TemplateItems,
    resource_attachments : Array(ResourceAttachment) = [] of ResourceAttachment,
    attachments : Array(Attachment) = [] of Attachment,
    cc : String | Array(String) = [] of String,
    bcc : String | Array(String) = [] of String,
    from : String | Array(String) | Nil = nil,
    reply_to : String | Array(String) | Nil = nil
  )
    metadata_template = if (zone_ids = args["zone_ids"]?) && zone_ids.is_a?(Array(String))
                          find_template?(template.join(SEPERATOR), zone_ids)
                        end

    if metadata_template
      subject = build_template(metadata_template["subject"], args)
      text = build_template(metadata_template["text"]?, args) || ""
      html = build_template(metadata_template["html"]?, args) || ""
      from = metadata_template["from"] if metadata_template["from"]?
      reply_to = metadata_template["reply_to"] if metadata_template["reply_to"]?

      mailer.send_mail(to, subject, text, html, resource_attachments, attachments, cc, bcc, from, reply_to)
    else
      mailer.send_template(to, template, args, resource_attachments, attachments, cc, bcc, from, reply_to)
    end
  end

  alias Template = Hash(String, String)

  #                         zone_id,     timeout, templates
  alias TemplateCache = Hash(String, Tuple(Int64, Array(Template)))

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
  #       template["trigger"] = "#{event_name}#{SEPERATOR}#{notify}"
  #       # template["zone_id"] = org_zone_id unless template["zone_id"]?
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
