require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"

# This driver uses metadata templates to send emails via the SMTP mailer.
# It should be configured as Mailer_1 with the next mailer in the chain as Mailer_2.
#
# It also updates metadata in the staff API with available fields for use in email templates.
class Place::TemplateMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Mailer
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "Template Mailer"
  generic_name :Mailer
  description %(uses metadata templates to send emails via the SMTP mailer)

  default_settings({
    cache_timeout:    300, # timeout for the template cache
    keep_if_not_seen: 6,   # keep fields for x updates if not seen, -1 to keep forever, 0 to never keep
    timezone:         "Australia/Sydney",
    update_schedule:  "*/20 * * * *", # cron schedule for updating template fields
  })

  accessor staff_api : StaffAPI_1

  getter org_zone_ids : Array(String) { get_zone_ids?("org").not_nil! }
  getter region_zone_ids : Array(String) { get_zone_ids?("region").not_nil! }
  getter building_zone_ids : Array(String) { get_zone_ids?("building").not_nil! }
  getter level_zone_ids : Array(String) { get_zone_ids?("level").not_nil! }

  getter org_zone_id : String { get_local_zone_id(org_zone_ids).not_nil! }

  def mailer
    system.implementing(Interface::Mailer)[1]
  end

  SEPERATOR = "."

  @template_cache : TemplateCache = TemplateCache.new
  @cache_timeout : Int64 = 300

  # keep fields for x updates if not seen
  # -1 to keep forever
  # 0 to never keep
  # 1 to keep for 1 update
  @keep_if_not_seen : Int64 = 6
  @not_seen_times : Hash(String, Int64) = Hash(String, Int64).new

  @timezone : Time::Location = Time::Location.load("Australia/Sydney")
  @update_schedule : String? = nil

  def on_load
    on_update
  end

  def on_update
    @org_zone_ids = nil
    @region_zone_ids = nil
    @building_zone_ids = nil
    @level_zone_ids = nil

    @org_zone_id = nil

    @cache_timeout = setting?(Int64, :cache_timeout) || 300_i64
    @keep_if_not_seen = setting?(Int64, :keep_if_not_seen) || 6_i64

    timezone = setting?(String, :timezone).presence || "Australia/Sydney"
    @timezone = Time::Location.load(timezone)
    @update_schedule = setting?(String, :update_schedule).presence

    schedule.clear

    if update_schedule = @update_schedule
      schedule.cron(update_schedule, @timezone) do
        update_template_fields(org_zone_id)
      end
    end

    update_template_fields(org_zone_id)
  end

  def get_zone_ids?(tag : String) : Array(String)?
    staff_api.zones(tags: tag).get.as_a.map(&.[]("id").as_s)
  rescue error
    logger.warn(exception: error) { "unable to determine #{tag} zone ids" }
    nil
  end

  def get_local_zone_id(zone_ids : Array(String)) : String?
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine local zone id" }
    nil
  end

  def get_template_fields?(zone_id : String) : Hash(String, MetadataTemplateFields)?
    metadata = Metadata.from_json staff_api.metadata(zone_id, "email_template_fields").get["email_template_fields"].to_json
    Hash(String, MetadataTemplateFields).from_json metadata.details.to_json
  rescue error
    logger.warn(exception: error) { "unable to get email template fields from zone #{zone_id} metadata" }
    nil
  end

  def sticky_template_fields(zone_id : String) : Hash(String, MetadataTemplateFields)
    # keep nothing
    return Hash(String, MetadataTemplateFields).new if @keep_if_not_seen == 0

    current_fields = get_template_fields?(zone_id) || Hash(String, MetadataTemplateFields).new
    return current_fields if current_fields.empty?

    # keep forever
    return current_fields if @keep_if_not_seen == -1

    sticky_fields = Hash(String, MetadataTemplateFields).new

    current_fields.keys.each do |key|
      @not_seen_times[key] = @not_seen_times[key]? ? @not_seen_times[key] + 1 : 1_i64

      if @not_seen_times[key] <= @keep_if_not_seen
        sticky_fields[key] = current_fields[key]
      end
    end

    sticky_fields
  end

  def update_template_fields(zone_id : String)
    template_fields : Hash(String, MetadataTemplateFields) = sticky_template_fields(zone_id)

    system.implementing(Interface::MailerTemplates).each do |driver|
      # next if the driver is turned off, or anything else goes wrong
      begin
        driver_template_fields = Array(TemplateFields).from_json driver.template_fields.get.to_json
      rescue error
        logger.warn(exception: error) { "unable to get template fields from module #{driver.module_id}" }
        next
      end

      driver_template_fields = Array(TemplateFields).from_json driver.template_fields.get.to_json
      driver_template_fields.each do |field_list|
        template_fields["#{field_list[:trigger].join(SEPERATOR)}"] = MetadataTemplateFields.new(
          module_name: driver.module_name,
          name: field_list[:name],
          description: field_list[:description],
          fields: field_list[:fields],
        )
      end
    end

    template_fields.keys.each do |key|
      @not_seen_times[key] = 0_i64
    end

    self[:template_fields] = template_fields

    unless template_fields.empty?
      staff_api.write_metadata(id: zone_id, key: "email_template_fields", payload: template_fields, description: "Available fields for use in email templates").get
    end
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

  def generate_svg_qrcode(text : String) : String
    mailer.generate_svg_qrcode(text)
  end

  def generate_png_qrcode(text : String, size : Int32 = 128) : String
    mailer.generate_png_qrcode(text, size)
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

  # This driver does not have any templates of it's own.
  # It uses the TemplateFields from Interface::MailerTemplates.
  def template_fields : Array(TemplateFields)
    [] of TemplateFields
  end

  alias Template = Hash(String, String)

  #                         zone_id,     timeout, templates
  alias TemplateCache = Hash(String, Tuple(Int64, Array(Template)))

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

  struct MetadataTemplateFields
    include JSON::Serializable

    property module_name : String = ""
    property name : String = ""
    property description : String? = nil
    property fields : Array(NamedTuple(name: String, description: String)) = [] of NamedTuple(name: String, description: String)

    def initialize(
      @module_name : String,
      @name : String,
      @description : String? = nil,
      @fields : Array(NamedTuple(name: String, description: String)) = [] of NamedTuple(name: String, description: String)
    )
    end
  end
end
