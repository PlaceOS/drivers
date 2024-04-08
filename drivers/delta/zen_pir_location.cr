require "placeos-driver"
require "placeos-driver/interface/locatable"

require "./models/**"

class Delta::ZenPIRLocation < PlaceOS::Driver
  include Interface::Locatable

  descriptive_name "Zen PIR Locations"
  generic_name :PIR_Locations
  description %(maps zen control pir locations to map areas)

  accessor delta_api : Delta_1

  default_settings({
    site_name:    "My Office",
    zen_id:       12345,
    pir_mappings: [{
      building_zone: "building_zone_id",
      level_zone:    "level_zone_id",
      pirs:          [{
        pir: 1234,
        map: "area-1234",
      }],
    }],
    # seconds between polling
    poll_every: 10,
  })

  def on_load
    on_update
  end

  record PIR, pir : UInt32, map : String do
    include JSON::Serializable
  end

  record PIRMap, building_zone : String, level_zone : String, pirs : Array(PIR) do
    include JSON::Serializable
  end

  def on_update
    @site_name = setting(String, :site_name)
    @zen_id = setting(UInt32, :zen_id)
    @pir_mappings = setting(Array(PIRMap), :pir_mappings)

    poll_every = setting?(Int32, :poll_every) || 10

    @cached_data = Hash(String, Array(Location)).new { |hash, key| hash[key] = [] of Location }
    schedule.clear
    schedule.every(poll_every.seconds) { cache_sensor_data }
  end

  getter site_name : String = "My Office"
  getter zen_id : UInt32 = 1234_u32
  getter pir_mappings : Array(PIRMap) = [] of PIRMap
  getter cached_data : Hash(String, Array(Location)) = {} of String => Array(Location)

  # ===================================
  # Locatable Interface functions
  # ===================================
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "sensor incapable of locating #{email} or #{username}" }
    [] of Nil
  end

  def macs_assigned_to(email : String? = nil, username : String? = nil) : Array(String)
    logger.debug { "sensor incapable of tracking #{email} or #{username}" }
    [] of String
  end

  def check_ownership_of(mac_address : String) : OwnershipMAC?
    logger.debug { "sensor incapable of tracking #{mac_address}" }
    nil
  end

  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching locatable in zone #{zone_id}" }
    return [] of Location if location.presence && location != "area"
    @cached_data[zone_id]? || [] of Location
  end

  # ===================================
  # Caching functions
  # ===================================

  struct Location
    include JSON::Serializable

    getter location : Symbol = :area
    property level : String
    property map_id : String
    property area_id : String
    property capacity : Int32
    property at_location : Int32

    property zen_device_id : UInt32
    property zen_object_id : UInt32

    def initialize(
      @level, @map_id, @area_id, @capacity, @at_location,
      @zen_device_id, @zen_object_id
    )
    end
  end

  protected def cache_sensor_data : Nil
    logger.debug { "caching sensor data" }

    # grab all the zen pir objects
    site = site_name
    device_id = zen_id
    cached_count = 0
    cached_data = Hash(String, Array(Location)).new { |hash, key| hash[key] = [] of Location }

    all_objects = pir_mappings.each do |pir_map|
      pir_map.pirs.each do |pir|
        begin
          prop = Models::ValueProperty.from_json delta_api.get_object_value(site, device_id, "binary-value", pir.pir).get.to_json
          next if (prop.out_of_service.try(&.value.as_i?) || 1) != 0

          state = prop.present_value.try do |pv|
            if string = pv.value.as_s?
              string.downcase
            end
          end

          next unless state.presence
          at_location = case state
                        when "inactive", "off"
                          0
                        when "active", "on"
                          1
                        else
                          logger.warn { "unexpected PIR value: #{state} for object #{pir.pir}.#{device_id}" }
                          next
                        end

          loc = Location.new(
            level: pir_map.level_zone,
            area_id: pir.map,
            map_id: pir.map,
            capacity: 1,
            at_location: at_location,
            zen_device_id: device_id,
            zen_object_id: pir.pir
          )

          cached_data[pir_map.building_zone] << loc
          cached_data[pir_map.level_zone] << loc
          cached_count += 1
        rescue error
          logger.warn(exception: error) { "error requesting object #{pir.pir} from zen #{device_id}" }
        end
      end
    end

    @cached_data = cached_data
    logger.debug { "cached #{cached_count} PIR objects" }
  end
end
