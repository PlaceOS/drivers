require "json"

# Desks are moving from the `desks` zone metadata to `_DESKS_` assets.
# The `use_desk_assets` setting (typically set once on the org zone and inherited)
# selects assets as the source of truth. Requires the including driver to provide `staff_api`.
#
# NOTE:: with assets, `Desk#id` is the `Asset#id`, which is what desk bookings reference
# once migrated (init `migrate:desk_assets`). With metadata it is the metadata desk id.
module Place::DeskSource
  DESK_ASSET_TYPE = "_DESKS_"
  DESK_METADATA   = "desks"

  # metadata keys with a dedicated field, the rest are kept in `other_data`.
  # matches init `migrate:desk_assets` so both sources present the same desk
  DESK_FIELDS = {"id", "map_id", "name", "bookable", "assigned_to", "assigned_name", "groups", "features", "images", "notes", "security"}

  struct Desk
    include JSON::Serializable

    getter id : String
    getter name : String
    getter map_id : String
    getter zone_id : String
    getter? bookable : Bool
    getter assigned_to : String?
    getter assigned_name : String?
    getter groups : Array(String)
    getter features : Array(String)
    getter images : Array(String)
    getter notes : String?
    getter security : Array(String)

    # custom fields, such as third party ids (`floorsense_id`)
    getter other_data : Hash(String, JSON::Any)

    def initialize(
      @id : String,
      @name : String,
      @map_id : String,
      @zone_id : String,
      @bookable : Bool = true,
      @assigned_to : String? = nil,
      @assigned_name : String? = nil,
      @groups : Array(String) = [] of String,
      @features : Array(String) = [] of String,
      @images : Array(String) = [] of String,
      @notes : String? = nil,
      @security : Array(String) = [] of String,
      @other_data : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end

    def []?(key : String) : JSON::Any?
      other_data[key]?
    end

    def self.from_asset(json : JSON::Any) : Desk?
      return unless asset = json.as_h?
      return unless id = string(asset["id"]?)
      other_data = asset["other_data"]?.try(&.as_h?) || {} of String => JSON::Any

      new(
        id: id,
        name: string(asset["identifier"]?) || string(asset["name"]?) || id,
        map_id: string(asset["map_id"]?) || string(other_data["map_id"]?) || id,
        zone_id: string(asset["zone_id"]?) || "",
        bookable: bool(asset["bookable"]?),
        assigned_to: string(asset["assigned_to"]?),
        assigned_name: string(asset["assigned_name"]?),
        groups: strings(asset["place_groups"]?),
        features: strings(asset["features"]?),
        images: strings(asset["images"]?),
        notes: string(asset["notes"]?),
        security: strings(asset["security_system_groups"]?),
        other_data: other_data,
      )
    end

    def self.from_metadata(json : JSON::Any, zone_id : String) : Desk?
      return unless desk = json.as_h?
      id = string(desk["id"]?)
      return unless map_id = string(desk["map_id"]?) || id
      id ||= map_id

      new(
        id: id,
        name: string(desk["name"]?) || id,
        map_id: map_id,
        zone_id: zone_id,
        bookable: bool(desk["bookable"]?),
        assigned_to: string(desk["assigned_to"]?),
        assigned_name: string(desk["assigned_name"]?),
        groups: strings(desk["groups"]?),
        features: strings(desk["features"]?),
        images: strings(desk["images"]?),
        notes: string(desk["notes"]?),
        security: string(desk["security"]?).try { |group| [group] } || [] of String,
        other_data: desk.reject { |key, _| DESK_FIELDS.includes?(key) },
      )
    end

    protected def self.string(value : JSON::Any?) : String?
      value.try(&.as_s?).presence
    end

    protected def self.strings(value : JSON::Any?) : Array(String)
      value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
    end

    # desks are bookable unless explicitly disabled, some metadata uses strings ("FALSE")
    protected def self.bool(value : JSON::Any?) : Bool
      return true unless value
      if string = value.as_s?
        string.downcase != "false"
      else
        value.as_bool? != false
      end
    end
  end

  def use_desk_assets? : Bool
    !!setting?(Bool, :use_desk_assets)
  end

  # the desks on a level
  def level_desks(level_id : String) : Array(Desk)
    use_desk_assets? ? asset_desks(zone_id: level_id) : metadata_level_desks(level_id)
  end

  # level zone id => the desks on that level
  def building_desks(building_id : String) : Hash(String, Array(Desk))
    desks = use_desk_assets? ? asset_desks(zones: [building_id]) : metadata_building_desks(building_id)
    desks.group_by(&.zone_id)
  end

  # Assets
  ###############################################################################################

  @desk_asset_type_ids : Array(String)? = nil

  protected def asset_desks(zone_id : String? = nil, zones : Array(String)? = nil) : Array(Desk)
    desk_asset_type_ids.flat_map do |type_id|
      desks = [] of Desk
      next_page = nil

      loop do
        page = staff_api.assets(type_id: type_id, zone_id: zone_id, zones: zones, next_page: next_page).get.as_a
        page.each { |asset| Desk.from_asset(asset).try { |desk| desks << desk } }
        next_page = page.first?.try(&.["next_page"]?).try(&.as_s?)
        break unless next_page
      end

      desks
    end
  end

  protected def desk_asset_type_ids : Array(String)
    if ids = @desk_asset_type_ids
      return ids
    end

    ids = staff_api.asset_types.get.as_a
      .select { |asset_type| asset_type["name"]?.try(&.as_s?) == DESK_ASSET_TYPE }
      .map(&.["id"].as_s).uniq!

    # don't cache a miss, the desk type may not have been created yet
    @desk_asset_type_ids = ids unless ids.empty?
    ids
  end

  # Metadata
  ###############################################################################################

  @[Deprecated("desk metadata: set use_desk_assets and remove")]
  protected def metadata_level_desks(level_id : String) : Array(Desk)
    details = staff_api.metadata(level_id, DESK_METADATA).get[DESK_METADATA]?.try(&.["details"]?)
    parse_metadata_desks(details, level_id)
  end

  @[Deprecated("desk metadata: set use_desk_assets and remove")]
  protected def metadata_building_desks(building_id : String) : Array(Desk)
    staff_api.metadata_children(building_id, DESK_METADATA).get.as_a.flat_map do |child|
      zone_id = child["zone"]["id"].as_s
      parse_metadata_desks(child.dig?("metadata", DESK_METADATA, "details"), zone_id)
    end
  end

  private def parse_metadata_desks(details : JSON::Any?, zone_id : String) : Array(Desk)
    return [] of Desk unless details
    unless desks = details.as_a?
      logger.warn { "desk metadata on #{zone_id} is not a list, desks may have been migrated to assets (use_desk_assets)" }
      return [] of Desk
    end
    desks.compact_map { |desk| Desk.from_metadata(desk, zone_id) }
  end
end
