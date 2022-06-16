require "placeos-driver"
require "./models"

# docs: https://vergesense.readme.io/reference/reference-getting-started

class Vergesense::VergesenseAPI < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Vergesense API"
  generic_name :Vergesense
  uri_base "https://api.vergesense.com"
  description "for more information visit: https://vergesense.readme.io/"

  default_settings({
    vergesense_api_key: "VS-API-KEY",
  })

  @api_key : String = ""

  @buildings : Array(Building) = [] of Building
  @floors : Hash(String, Floor) = {} of String => Floor
  @spaces : Hash(String, String) = {} of String => String

  @debug_payload : Bool = false
  @poll_every : Time::Span? = nil
  @sync_lock : Mutex = Mutex.new

  def on_load
    on_update
    schedule.in(200.milliseconds) { init_sync }
  end

  def on_update
    @api_key = setting(String, :vergesense_api_key)
    @debug_payload = setting?(Bool, :debug_payload) || false

    @poll_every = setting?(Int32, :poll_every).try &.seconds

    schedule.clear
    if poll_time = @poll_every
      schedule.every(poll_time) { init_sync }
    end
  end

  # Performs initial sync by loading buildings / floors / spaces
  def init_sync
    @sync_lock.synchronize do
      init_buildings

      if @buildings
        init_floors
        init_spaces
        init_floors_status

        self["init_complete"] = true
      end
    end
  rescue e
    logger.error { "failed to perform vergesense API sync\n#{e.inspect_with_backtrace}" }
  end

  EMPTY_HEADERS    = {} of String => String
  SUCCESS_RESPONSE = {HTTP::Status::OK, EMPTY_HEADERS, nil}

  # Webhook endpoint for space_report API, expects version 2
  def space_report_api(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "space_report API received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_payload

    # Parse the data posted
    begin
      remote_space = Space.from_json(body)
      logger.debug { "parsed vergesense payload" }

      update_floor_space(remote_space)
      update_single_floor_status(remote_space.floor_key, @floors[remote_space.floor_key]?)
    rescue e
      logger.error { "failed to parse vergesense space_report API payload\n#{e.inspect_with_backtrace}" }
      logger.debug { "failed payload body was\n#{body}" }
    end

    # Return a 200 response
    SUCCESS_RESPONSE
  end

  def floor_key(space_id : String)
    @spaces[space_id]
  end

  private def init_buildings
    @buildings = Array(Building).from_json(get_request("/buildings"))
  end

  private def init_floors
    @buildings.not_nil!.each do |building|
      building_with_floors = BuildingWithFloors.from_json(get_request("/buildings/#{building.building_ref_id}"))
      if building_with_floors
        building_with_floors.floors.each do |floor|
          floor_key = "#{building.building_ref_id}-#{floor.floor_ref_id}".strip
          @floors[floor_key] = floor
        end
      end
    end
    @floors
  end

  private def init_spaces
    spaces = Array(Space).from_json(get_request("/spaces"))
    spaces.each do |remote_space|
      update_floor_space(remote_space)
    end

    spaces
  end

  private def init_floors_status
    @floors.each do |floor_key, floor|
      update_single_floor_status(floor_key, floor)
    end
  end

  private def update_single_floor_status(floor_key, floor)
    if floor_key && floor
      self[floor_key] = floor.not_nil!
    end
  end

  # Finds a space on a given floor and updates it in place.
  private def update_floor_space(remote_space)
    floor = @floors[remote_space.floor_key]?
    if floor
      floor_space = floor.spaces.find { |space| space.ref_id == remote_space.ref_id }
      if floor_space
        floor_space.building_ref_id = remote_space.building_ref_id
        floor_space.floor_ref_id = remote_space.floor_ref_id
        floor_space.people = remote_space.people
        floor_space.motion_detected = remote_space.motion_detected
        floor_space.timestamp = remote_space.timestamp
        floor_space.environment = remote_space.environment
        floor_space.name = remote_space.name if remote_space.name
        floor_space.capacity = remote_space.capacity if remote_space.capacity
        floor_space.max_capacity = remote_space.max_capacity if remote_space.max_capacity
        floor_space.signs_of_life = remote_space.signs_of_life
      else
        floor.spaces << remote_space
      end

      # cache the lookups for simple floor discovery
      if space_ref = remote_space.ref_id
        @spaces[space_ref] = remote_space.floor_key
      end
    end
  end

  private def get_request(path)
    response = get(path,
      headers: {
        "vs-api-key" => @api_key,
      }
    )

    if response.success?
      response.body
    else
      raise "unexpected response #{response.status_code}\n#{response.body}"
    end
  end
end
