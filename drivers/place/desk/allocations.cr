require "placeos-driver"
require "csv"

class Place::Desk::Allocations < PlaceOS::Driver
  descriptive_name "PlaceOS Desk Allocations"
  generic_name :DeskAllocations
  description %(helper for exporting and importing desk allocations)

  accessor staff_api : StaffAPI_1

  struct Zone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter tags : Array(String)

    property code : String?
    property parent_id : String?
  end

  getter buildings : Hash(String, Zone) do
    Array(Zone).from_json(staff_api.zones(tags: {"building"}).get.to_json).sort_by(&.name).to_h { |zone| {zone.id, zone} }
  end

  getter all_levels : Array(Zone) do
    Array(Zone).from_json(staff_api.zones(tags: {"level"}).get.to_json).sort_by(&.name)
  end

  struct Desk
    include JSON::Serializable

    getter id : String
    getter name : String
    getter level_code : String
    getter building_code : String
    getter allocation_email : String?

    def initialize(@id, @name, @level_code, @building_code, @allocation_email)
    end
  end

  def desks : Array(Desk)
    logger.debug { "getting list of all desks" }
    response = [] of Desk

    l = all_levels
    l.each do |level|
      logger.debug { " - processing level #{level.name}" }

      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      if all_desks && (building = buildings[level.parent_id]?)
        desks = all_desks.as_a

        building_code = building.code.presence || building.display_name.presence || building.name
        level_code = level.code.presence || level.display_name.presence || level.name

        desks.each do |desk|
          response << Desk.new(
            desk["id"].as_s,
            desk["name"].as_s?.presence || desk["id"].as_s,
            level_code,
            building_code,
            desk["assigned_to"]?.try(&.as_s?.presence)
          )
        end
      end
    end

    logger.debug { "found #{response.size} desks" }
    response
  end

  def get_desks(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }

    payload = CSV.build do |csv|
      csv.row "desk_id", "desk_name", "building", "level", "allocation_email"
      desks.each do |desk|
        csv.row desk.id, desk.name, desk.building_code, desk.level_code, desk.allocation_email
      end
    end

    {HTTP::Status::OK.to_i, {"Content-Type" => "text/csv"}, payload}
  end
end
