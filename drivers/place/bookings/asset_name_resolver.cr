require "json"
require "./locker_models"

module Place::AssetNameResolver
  include Place::LockerMetadataParser

  @asset_cache : AssetCache = AssetCache.new
  @asset_cache_timeout : Int64 = 3600_i64 # 1 hour
  
  private getter asset_cache : AssetCache

  private def clear_asset_cache
    @asset_cache = AssetCache.new
  end

  private def lookup_asset(asset_id : String, type : String, zones : Array(String) = [building_id]) : String
    if type == "locker"
      locker = locker_details[asset_id]?
      return locker.name if locker
    else
      zones.each do |zone_id|
        asset = if (cache = asset_cache[{zone_id, type}]?) && cache[0] > Time.utc.to_unix
                  cache[1].find { |asset| asset.id == asset_id }
                else
                  assets = lookup_assets(zone_id, type)
                  @asset_cache[{zone_id, type}] = {Time.utc.to_unix + @asset_cache_timeout, assets}
                  assets.find { |asset| asset.id == asset_id }
                end

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
      metadata = Metadata.from_json staff_api.metadata(zone_id, metadata_field).get[metadata_field].to_json
      assets = metadata.details.as_a.map { |asset| Asset.from_json asset.to_json }
    elsif type == "locker"
      assets = locker_details.map { |id, locker| Asset.new(id, locker.name) }
    end

    assets
  rescue error
    logger.debug { "unable to get #{metadata_field} from zone #{zone_id} metadata" }
    [] of Asset
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
