require "placeos-driver"
require "./chat_bot_models"

class Pattr::ChatBot < PlaceOS::Driver
  descriptive_name "Pattr Chat Bot"
  generic_name :ChatBot
  description %(provides data based on context provided by the chat bot)

  default_settings({
    debug_webhook: false,
    # building location services, defualts to the current system
    buildings: ["system_id1"],
  })

  @debug_webhook : Bool = false
  @buildings : Array(PlaceOS::Driver::Proxy::System) = [] of PlaceOS::Driver::Proxy::System

  accessor staff_api : StaffAPI_1

  protected getter zones : Hash(String, String) = {} of String => String
  protected getter systems : Hash(String, String) = {} of String => String

  def on_load
    @zones = Hash(String, String).new do |hash, key|
      zone = staff_api.zone(key).get.as_h
      hash[key] = zone["display_name"]?.try(&.as_s?.try(&.presence)) || zone["name"].as_s
    end

    @systems = Hash(String, String).new do |hash, key|
      zone = staff_api.get_system(key).get.as_h
      hash[key] = zone["display_name"]?.try(&.as_s?.try(&.presence)) || zone["name"].as_s
    end

    on_update
  end

  def on_update
    @debug_webhook = setting?(Bool, :debug_webhook) || false

    # Convert the building system IDs to system proxies
    buildings = setting?(Array(String), :buildings) || [config.control_system.not_nil!.id]
    @buildings = buildings.map { |id| system(id) }
  end

  def chat_data_request(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "IP mappings webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_webhook

    request = Request.from_json(body)
    response = case request
               in Location
                 locate(request.referencing)
               end

    payload = response.to_json
    logger.debug { payload } if @debug_webhook
    {HTTP::Status::OK, {"Content-Type" => "application/json"}, payload}
  end

  # map reduce search for the users across all buildings
  def locate(staff : Array(String))
    # kick off the searches
    searches = staff.map do |username|
      email = username.includes?('@') ? username : nil
      queries = @buildings.map { |building| building[:LocationServices].locate_user(email, username) }
      {username, queries}
    end

    # wait for the responses to flow in
    response = {} of String => PlaceLocationResult
    searches.each do |(username, queries)|
      locations = {} of String => PlaceLocationResult
      queries.each do |results|
        Array(PlaceLocationResult).from_json(results.get.to_json).map do |location|
          locations[location.location] = location
        end
      end

      # Grab the location they are most likely to be
      if location = locations["meeting"]? || locations["wireless"]? || locations["desk"]?
        response[username] = location
      end
    end

    # build the response
    response.transform_values do |location|
      case location.location
      when "meeting"
        {
          building: zones[location.building],
          level:    zones[location.level],
          room:     systems[location.sys_id.not_nil!],
        }
      else
        {
          building: zones[location.building],
          level:    zones[location.level],
        }
      end
    end
  end
end
