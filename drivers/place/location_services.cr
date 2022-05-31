require "set"
require "json"
require "placeos-driver"
require "placeos-driver/interface/locatable"
require "placeos-driver/interface/sensor"

class Place::LocationServices < PlaceOS::Driver
  descriptive_name "PlaceOS Location Services"
  generic_name :LocationServices
  description %(collects location data from compatible services and combines the data)

  default_settings({
    debug_webhook:   false,
    search_building: false,

    # various groups of people one might be interested in contacting
    emergency_contacts: {
      "Fire Wardens" => "5542c9f-eaa7-4e74",
      "First Aid"    => "ed9f7608-488f-aeef",
    },
  })

  def on_load
    on_update
  end

  @debug_webhook : Bool = false
  @emergency_contacts : Hash(String, String) = {} of String => String
  @search_building : Bool = true

  getter building_id : String { get_building_id.not_nil! }
  getter systems : Hash(String, Array(String)) { get_systems_list.not_nil! }

  def on_update
    @debug_webhook = setting?(Bool, :debug_webhook) || false
    @emergency_contacts = setting?(Hash(String, String), :emergency_contacts) || Hash(String, String).new
    @search_building = setting?(Bool, :search_building) || false
    @building_id = nil
    @systems = nil

    schedule.clear

    # Keep mappings up to date
    if @search_building
      schedule.every(1.hour) { @systems = get_systems_list.not_nil! if @systems }
    end

    if !@emergency_contacts.empty?
      schedule.every(6.hours, immediate: true) { update_contacts_list }
    end
  end

  # Finds the building ID for the current location services object
  def get_building_id
    zone_ids = system["StaffAPI"].zones(tags: "building").get.as_a.map(&.[]("id").as_s)
    (zone_ids & system.zones).first
  rescue error
    logger.warn(exception: error) { "unable to determine building zone id" }
    nil
  end

  # Grabs the list of systems in the building
  def get_systems_list
    system["StaffAPI"].systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  rescue error
    logger.warn(exception: error) { "unable to obtain list of systems in the building" }
    nil
  end

  # Runs through all the services that support the Locatable interface
  # requests location information on the identifier for all of them
  # concatenates the results and returns them as a single array
  def locate_user(email : String? = nil, username : String? = nil)
    email = email.try &.downcase
    logger.debug { "searching for #{email}, #{username}" }
    located = [] of JSON::Any
    system.implementing(Interface::Locatable).locate_user(email, username).get.each do |locations|
      located.concat locations.as_a
    end

    if @search_building
      building = JSON::Any.new building_id
      results = [] of Tuple(JSON::Any, PlaceOS::Driver::Proxy::Drivers::Responses)

      # Map
      systems.each do |level_id, system_ids|
        level_id = JSON::Any.new level_id
        system_ids.each do |system_id|
          results << {level_id, system(system_id).implementing(Interface::Locatable).locate_user(email, username)}
        end
      end

      # reduce
      results.each do |(level_id, result)|
        result.get.each do |locations|
          located.concat(locations.as_a.tap &.each { |location|
            location = location.as_h
            location["level"] = level_id
            location["building"] = building
          })
        end
      end
    end

    located
  end

  # Will return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil)
    email = email.try &.downcase
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }
    macs = [] of String
    system.implementing(Interface::Locatable).macs_assigned_to(email, username).get.each do |found|
      macs.concat found.as_a.map(&.as_s)
    end

    if @search_building
      results = [] of PlaceOS::Driver::Proxy::Drivers::Responses

      # Map
      systems.each do |_level_id, system_ids|
        system_ids.each do |system_id|
          results << system(system_id).implementing(Interface::Locatable).macs_assigned_to(email, username)
        end
      end

      # reduce
      results.each &.get.each { |found| macs.concat found.as_a.map(&.as_s) }
    end

    macs
  end

  # Will return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String)
    logger.debug { "searching for owner of #{mac_address}" }
    owner = nil
    system.implementing(Interface::Locatable).check_ownership_of(mac_address).get.each do |result|
      if result != nil
        owner = result
        break
      end
    end

    if owner.nil? && @search_building
      results = [] of PlaceOS::Driver::Proxy::Drivers::Responses

      # Map
      systems.each do |_level_id, system_ids|
        system_ids.each do |system_id|
          results << system(system_id).implementing(Interface::Locatable).check_ownership_of(mac_address)
        end
      end

      # reduce
      results.each do |sys_results|
        sys_results.get.each do |result|
          if result != nil
            owner = result
            break
          end
        end
        break unless owner.nil?
      end
    end

    owner
  end

  # Will return an array of devices and their x, y coordinates
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    located = [] of JSON::Any
    system.implementing(Interface::Locatable).device_locations(zone_id, location).get.each do |locations|
      located.concat locations.as_a
    end
    located
  end

  # ===============================
  # Sensor data collection
  # ===============================

  # sensor search + filtered search
  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil)
    logger.debug { "searching sensors of type: #{type.inspect}, mac: #{mac.inspect}, zone_id: #{zone_id}" }
    located = [] of JSON::Any

    drivers = system.implementing(Interface::Sensor)
    drivers.sensors(type, mac, zone_id).get.each do |locations|
      located.concat locations.as_a
    end

    driver_ids = Set.new drivers.map(&.@module_id)

    if @search_building
      building = JSON::Any.new building_id
      results = [] of Tuple(JSON::Any, PlaceOS::Driver::Proxy::Drivers::Responses)

      # Map
      systems.each do |level_id, system_ids|
        next if zone_id && zone_id != level_id
        level_id = JSON::Any.new level_id
        system_ids.each do |system_id|
          # ensure we don't query modules more than once
          drivers = system(system_id).implementing(Interface::Sensor)
          drivers = PlaceOS::Driver::Proxy::Drivers.new(drivers.reject { |driver| driver.@module_id.in?(driver_ids) })
          driver_ids.concat drivers.map(&.@module_id)

          results << {level_id, drivers.sensors(type, mac, zone_id)}
        end
      end

      # reduce
      results.each do |(level_id, result)|
        result.get.each do |locations|
          located.concat(locations.as_a.tap &.each { |location|
            location = location.as_h
            location["level"] = level_id
            location["building"] = building
          })
        end
      end
    end

    located
  end

  def sensor(mac : String, id : String? = nil)
    logger.debug { "querying sensor with mac: #{mac}, id: #{id.inspect}" }
    located = [] of JSON::Any
    drivers = system.implementing(Interface::Sensor)
    drivers.sensor(mac, id).get.each do |locations|
      located.concat locations.as_a
    end

    return located.first unless located.empty?

    driver_ids = Set.new drivers.map(&.@module_id)

    if @search_building
      building = JSON::Any.new building_id
      results = [] of Tuple(JSON::Any, PlaceOS::Driver::Proxy::Drivers::Responses)

      # Map
      systems.each do |level_id, system_ids|
        level_id = JSON::Any.new level_id
        system_ids.each do |system_id|
          # ensure we don't query modules more than once
          drivers = system(system_id).implementing(Interface::Sensor)
          drivers = PlaceOS::Driver::Proxy::Drivers.new(drivers.reject { |driver| driver.@module_id.in?(driver_ids) })
          driver_ids.concat drivers.map(&.@module_id)

          results << {level_id, drivers.sensor(mac, id)}
        end
      end

      # reduce
      results.each do |(level_id, result)|
        result.get.each do |locations|
          located.concat(locations.as_a.tap &.each { |location|
            location = location.as_h
            location["level"] = level_id
            location["building"] = building
          })
        end
      end
    end

    located.first unless located.empty?
  end

  # ===============================
  # IP ADDRESS => MAC ADDRESS
  # ===============================
  SUCCESS_RESPONSE = {HTTP::Status::OK, {} of String => String, nil}

  # Webhook handler for accepting IP address to username mappings
  # This data is typically obtained via domain controller logs
  def ip_mappings(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "IP mappings webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_webhook

    # ip, username, domain, hostname
    ip_map = Array(Tuple(String, String, String, String?)).from_json(body)
    system.implementing(Interface::Locatable).ip_username_mappings(ip_map)

    SUCCESS_RESPONSE
  end

  def mac_address_mappings(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "MAC mappings webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }
    logger.debug { body } if @debug_webhook

    # username, macs, domain
    username, macs, domain = Tuple(String, Array(String), String?).from_json(body)
    username = username.strip
    macs = macs.compact_map do |mac|
      mac = mac.strip.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
      mac if mac.size == 12
    end
    return {HTTP::Status::NOT_ACCEPTABLE, {} of String => String, nil} if username.empty? || macs.empty?

    system.implementing(Interface::Locatable).mac_address_mappings(username, macs, domain)

    SUCCESS_RESPONSE
  end

  @[Security(Level::Support)]
  def update_contacts_list
    if @emergency_contacts.empty?
      self[:emergency_contacts] = nil
      return
    end

    if !system.exists?(:Calendar)
      logger.warn { "contacts requested however no directory service available" }
      return
    end

    directory = system[:Calendar]
    self[:emergency_contacts] = @emergency_contacts.transform_values { |id|
      directory.get_members(id).get.as(JSON::Any)
    }
  end

  # locates all the of the emergency contacts
  def locate_contacts(list_name : String)
    contacts = status(Hash(String, Array(NamedTuple(
      email: String,
      username: String))), :emergency_contacts)

    list = contacts[list_name]
    results = {} of String => Array(JSON::Any)
    list.each do |person|
      email = person[:email]
      results[email] = locate_user(email, person[:username])
    end
    results
  end
end
