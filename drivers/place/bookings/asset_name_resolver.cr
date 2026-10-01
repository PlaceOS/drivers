require "json"
require "./locker_models"

module Place::AssetNameResolver
  include Place::LockerMetadataParser

  @asset_cache : AssetCache = AssetCache.new
  @asset_record_cache : AssetCache = AssetCache.new
  @asset_type_cache = {} of String => Tuple(Int64, Array(String))
  @asset_cache_timeout : Int64 = 3600_i64 # 1 hour

  private getter asset_cache : AssetCache

  private def clear_asset_cache
    @asset_cache = AssetCache.new
    @asset_record_cache = AssetCache.new
    @asset_type_cache.clear
  end

  private def lookup_asset(asset_id : String, type : String, zones : Array(String) = [building_id]) : String
    if type == "locker"
      locker = locker_details[asset_id]?
      return locker.name if locker
    else
      zones.each do |zone_id|
        asset = lookup_assets(zone_id, type).find { |asset| asset.id == asset_id }
        return asset.name if asset

        asset = lookup_asset_records(zone_id, type).find { |asset| asset.id == asset_id }
        return asset.name if asset
      end
    end

    logger.debug { "unable to resolve asset name for #{asset_id}" }
    asset_id
  end

  private def lookup_assets(zone_id : String, type : String) : Array(Asset)
    assets = [] of Asset

    metadata_field = case type
                     when "desk"
                       "desks"
                     when "parking"
                       "parking-spaces"
                     end

    if metadata_field
      if (cache = asset_cache[{zone_id, type}]?) && cache[0] > Time.utc.to_unix
        return cache[1]
      end

      details = begin
        metadata = Metadata.from_json staff_api.metadata(zone_id, metadata_field).get[metadata_field].to_json
        metadata.details.as_a?
      rescue error
        logger.debug { "unable to get #{metadata_field} from zone #{zone_id} metadata" }
        nil
      end

      assets = if details
                 details.map { |asset| Asset.from_json asset.to_json }
               else
                 lookup_asset_records(zone_id, type)
               end
      @asset_cache[{zone_id, type}] = {Time.utc.to_unix + @asset_cache_timeout, assets}
    elsif type == "locker"
      assets = locker_details.map { |id, locker| Asset.new(id, locker.name) }
    end

    assets
  rescue error
    logger.debug { "unable to get #{metadata_field} from zone #{zone_id} metadata" }
    [] of Asset
  end

  private def lookup_asset_records(zone_id : String, type : String) : Array(Asset)
    assets = [] of Asset
    type_name = case type
                when "desk"    then "_DESKS_"
                when "parking" then "_PARKING_SPACES_"
                end
    return assets unless type_name

    if (cache = @asset_record_cache[{zone_id, type}]?) && cache[0] > Time.utc.to_unix
      return cache[1]
    end

    begin
      type_ids = if (cache = @asset_type_cache[type]?) && cache[0] > Time.utc.to_unix
                   cache[1]
                 else
                   ids = staff_api.asset_types.get.as_a.select { |asset_type| asset_type["name"]?.try(&.as_s?) == type_name }
                     .map { |asset_type| asset_type["id"].as_s }.uniq!
                   @asset_type_cache[type] = {Time.utc.to_unix + @asset_cache_timeout, ids}
                   ids
                 end

      type_ids.each do |type_id|
        begin
          staff_api.assets(type_id: type_id, zone_id: zone_id).get.as_a.each do |asset|
            id = asset["id"].as_s
            name = asset["identifier"]?.try(&.as_s?).presence || asset["name"]?.try(&.as_s?).presence || id
            assets << Asset.new(id, name)
          end
        rescue error
          logger.warn(exception: error) { "unable to get #{type_id} assets from zone #{zone_id}" }
        end
      end
    rescue error
      logger.warn(exception: error) { "unable to get #{type} asset types for zone #{zone_id}" }
    end

    assets.uniq!(&.id)
    @asset_record_cache[{zone_id, type}] = {Time.utc.to_unix + @asset_cache_timeout, assets}
    assets
  end

  #                            zone_id, type         timeout, assets
  alias AssetCache = Hash(Tuple(String, String), Tuple(Int64, Array(Asset)))

  struct Asset
    include JSON::Serializable

    property id : String
    property name : String

    def initialize(@id : String, @name : String)
    end
  end

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
end
