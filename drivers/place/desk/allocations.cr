require "placeos-driver"
require "http"
require "csv"

class Place::Desk::Allocations < PlaceOS::Driver
  descriptive_name "PlaceOS Desk Allocations"
  generic_name :DeskAllocations
  description %(helper for exporting and importing desk allocations)

  accessor staff_api : StaffAPI_1
  accessor calendar : Calendar_1

  default_settings({
    allocation_list_url: "http://org.com/desk/allocations",
    polling_cron:        "*/15 * * * *",
    testing:             false,
  })

  @allocation_list_url : String = "http://org.com/desk/allocations"

  getter testing : Bool = false

  def on_update
    @allocation_list_url = setting(String, :allocation_list_url)
    @testing = setting?(Bool, :testing) || false
    schedule.clear
    schedule.cron(setting(String, :polling_cron)) { pull_and_sync_desk_allocations(testing) }
  end

  struct Zone
    include JSON::Serializable

    getter id : String
    getter name : String
    getter display_name : String?
    getter tags : Array(String)
    getter timezone : String?

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
    getter bookable : Bool
    getter features : String?
    getter level_code : String
    getter building_code : String
    getter allocation_email : String?

    getter building_id : String
    getter level_id : String

    # TODO:: dont think I need this
    # getter org : String
    # getter campus : String

    def initialize(@id, @name, @bookable, @features, @level_code, @building_code, @allocation_email, @building_id, @level_id)
    end
  end

  def desks : Hash(String, Desk)
    logger.debug { "getting list of all desks" }
    response = {} of String => Desk

    l = all_levels
    l.each do |level|
      logger.debug { " - processing level #{level.name}" }

      all_desks = staff_api.metadata(level.id, "desks").get.dig?("desks", "details")
      if all_desks && (building = buildings[level.parent_id]?)
        desks = all_desks.as_a

        building_code = building.code.presence || building.display_name.presence || building.name
        level_code = level.code.presence || level.display_name.presence || level.name

        desks.each do |desk|
          desk_id = desk["id"].as_s
          response[desk_id] = Desk.new(
            desk_id,
            desk["name"].as_s?.presence || desk["id"].as_s,
            desk["bookable"].as_bool,
            desk["features"].as_a?.try(&.map(&.as_s).first?),
            level_code,
            building_code,
            desk["assigned_to"]?.try(&.as_s?.presence.try(&.downcase)),
            building.id,
            level.id
          )
        end
      end
    end

    logger.debug { "found #{response.size} desks" }
    response
  end

  # Provides a list of desk information to a desk management tool
  def get_desks(method : String, headers : Hash(String, Array(String)), body : String)
    logger.debug { "webhook received: #{method},\nheaders #{headers},\nbody size #{body.size}" }

    payload = CSV.build do |csv|
      csv.row "desk_id", "desk_name", "building", "level", "allocation_email", "desk_type"
      # Staff, Student, Staff Hot Desk, Student Hot Desk, Hot Desk
      # unallocated + bookable == hot desk
      # HDR in features == Student
      desks.values.each do |desk|
        allocated_email = desk.allocation_email.presence
        desk_type = if allocated_email.nil? && desk.bookable
                      # hot desk
                      desk.features.try(&.downcase.includes?("hdr")) ? "Student Hot Desk" : "Staff Hot Desk"
                    elsif allocated_email
                      # assigned desk
                      allocated_email.includes?("student") ? "Student" : "Staff"
                    else
                      # unallocated
                      "Staff"
                    end

        csv.row desk.id, desk.name, desk.building_code, desk.level_code, desk.allocation_email, desk_type
      end
    end

    {HTTP::Status::OK.to_i, {"Content-Type" => "text/csv"}, payload}
  end

  struct Allocation
    include JSON::Serializable

    getter desk_id : String
    getter desk_name : String
    getter email : String?
    getter bookable : Bool

    def initialize(@desk_id, @desk_name, allocation : String?, @bookable)
      @email = allocation.try(&.strip.downcase)
    end
  end

  def pull_and_sync_desk_allocations(test : Bool = true)
    # pulls the allocations from the remote server
    pull_allocations(test)

    # syncs the recurring meetings associated with the allocations
    # deleting old and adding in the new
    sync_allocations(test)
  end

  def pull_allocations(test : Bool = true)
    # get the list of desks
    # TODO:: check if the desks
    all_desks = desks

    # fetch the allocation CSV
    response = HTTP::Client.get(@allocation_list_url)
    raise "failed to fetch desk allocations with #{response.status}\n#{response.body}" unless response.success?

    # parse the CSV and check each allocation and for any name updates
    # "PlaceOS ID","Name","Assigned To","desk Type" (Staff, Student, Staff Hot Desk, Student Hot Desk, Hot Desk)
    # "desk-6.43.19","6.43.19","Roopali.Misra@cdu.edu.au"
    csv = CSV.new(response.body, headers: true, strip: true)
    csv_allocations = {} of String => Allocation

    loop do
      break unless csv.next
      row = csv.row
      desk_id = row[0]
      allocated_email = row[2].downcase.presence
      bookable = !!allocated_email || row[3].includes?("Hot")
      csv_allocations[desk_id] = Allocation.new(desk_id, row[1], allocated_email, bookable)
    end

    level_allocations = Hash(String, Array(Allocation)).new do |hash, level_id|
      hash[level_id] = [] of Allocation
    end

    # find new allocations
    new_allocations = 0
    csv_allocations.each do |desk_id, allocation|
      desk = all_desks[desk_id]?
      if desk.nil?
        logger.warn { "desk #{desk_id} not configured in metadata" }
        next
      end

      next if desk.allocation_email == allocation.email

      level_allocations[desk.level_id] << allocation
      new_allocations += 1
    end
    logger.debug { "found #{new_allocations} new allocations" }

    # find any desks whos allocation has been removed
    # (the CSV only returns the current allocations)
    removed_allocations = 0
    all_desks.each do |desk_id, desk|
      allocation = csv_allocations[desk_id]?
      next if allocation

      # skip unless there is an email presence
      allocated_email = desk.allocation_email
      next unless allocated_email

      removed_allocations += 1
      hot_desk = desk.features.try(&.downcase.includes?("hdr"))
      level_allocations[desk.level_id] << Allocation.new(desk_id, desk.name, nil, !!hot_desk)
    end
    logger.debug { "found #{removed_allocations} allocations to be removed" }

    logger.debug do
      String.build do |str|
        str << "allocation changes:\n"
        level_allocations.each do |level, allocations|
          str << " - lvl #{level}: #{allocations.inspect}\n"
        end
      end
    end

    # update the allocation metadata
    return if test
    level_allocations.each do |level_id, allocations|
      update_allocation_metadata(level_id, allocations)
    end
  end

  # set the users in the metadata
  protected def update_allocation_metadata(level_zone : String, allocations : Array(Allocation))
    # fetch the level metadata
    all_desks = staff_api.metadata(level_zone, "desks").get.dig?("desks", "details").try(&.as_a?)
    return unless all_desks

    allocation_hash = allocations.to_h { |alloc| {alloc.desk_id, alloc} }

    # update the json with allocation changes
    updated_desks = all_desks.map do |desk|
      desk_id = desk["id"].as_s
      allocation = allocation_hash[desk_id]?
      desk = desk.as_h
      next desk unless allocation

      if email = allocation.email.presence
        # look up users name
        user_name = begin
          calendar.get_user(email).get["name"].as_s
        rescue error
          logger.error(exception: error) { "failed to find allocation name for #{allocation.email}" }
          email.split("@")[0].split(' ').map(&.capitalize).join(' ')
        end
      else
        user_name = ""
      end

      desk["name"] = JSON::Any.new(allocation.desk_name)
      desk["assigned_to"] = JSON::Any.new(email)
      desk["assigned_name"] = JSON::Any.new(user_name)
      desk["bookable"] = JSON::Any.new(allocation.bookable)
      desk
    end

    # update the level metadata
    begin
      staff_api.write_metadata(level_zone, "desks", updated_desks).get
    rescue error
      logger.error(exception: error) { "failed to write metadata for level: #{level_zone}" }
    end
  end

  # Syncs all the allocations
  def sync_allocations(test : Bool = true)
    buildings.keys.each do |building_id|
      sync_allocations_in(building_id, test)
    end
  end

  # ==============================
  # Desk allocation syncronisation
  # ==============================

  protected def building_details(building_id : String) : Tuple(Time::Location, Array(String))
    building_details = buildings[building_id]
    logger.debug { "syncing allocations in: #{building_details.name}\n====================" }

    if building_parent = building_details.parent_id.presence
      parent_details = staff_api.zone(building_parent).get
      parent_parent = parent_details["parent_id"]?.try(&.as_s?)
    end

    tz = building_details.timezone.presence || config.control_system.try(&.timezone)
    {Time::Location.load(tz.as(String)), [parent_parent, building_parent].compact}
  end

  record AssignmentDetails, desk_id : String, assigned_email : String, assigned_name : String, level_zone : String, desk_name : String

  protected def sync_allocations_in(building_zone : String, test : Bool)
    # find the parent zones for the building
    timezone, parent_zones = building_details(building_zone)

    # sync code as per the script
    desk_ids = Set(String).new

    # email => [] of desks
    assigned_to = Hash(String, Array(AssignmentDetails)).new do |hash, key|
      hash[key] = [] of AssignmentDetails
    end

    # desk_id => DeskDetails
    assignments = {} of String => AssignmentDetails

    # get the desk assignments
    json = staff_api.metadata_children(building_zone, "desks").get
    json.as_a.each do |level|
      level_zone = level["zone"]["id"].as_s

      if desks = level["metadata"]["desks"]?
        desks["details"].as_a.each do |desk|
          assigned_email = desk["assigned_to"]?.try(&.as_s?).presence
          next unless assigned_email
          assigned_email = assigned_email.strip.downcase
          assigned_name = desk["assigned_name"]?.try(&.as_s?)

          if assigned_name.nil?
            logger.warn { "no assigned name for desk #{assigned_email}" }
            assigned_name = assigned_email.split('@')[0].gsub('.', ' ')
          end

          desk_id = desk["id"].as_s
          desk_name = desk["name"]?.try(&.as_s?) || desk_id
          details = AssignmentDetails.new(desk_id, assigned_email, assigned_name, level_zone, desk_name)

          assignments[desk_id] = details
          assigned_to[assigned_email] << details
        end
      end
    end

    # find all the booking allocation ids
    starting = Time.local(timezone)
    ending = 2.hours.from_now

    booking_start = starting.at_beginning_of_day
    booking_end = starting.at_end_of_day

    bookings = staff_api.query_bookings(
      type: "desk",
      zones: {building_zone},
      limit: 10_000,
      period_start: starting.to_unix,
      period_end: ending.to_unix
    ).get.as_a

    bookings.select! { |booking| booking["recurrence_type"].as_s? == "daily" && booking["recurrence_end"]?.try(&.as_i64?).nil? && booking["booking_type"].as_s == "desk" }

    # find all the missing assignments or incorrect assignments
    missing = {} of String => AssignmentDetails
    deleted = {} of Int64 => String
    failed = 0
    assignments.each do |desk_id, details|
      booking = bookings.find { |book| book["asset_id"].as_s == desk_id }
      if booking.nil?
        missing[desk_id] = details
        next
      end

      booking_email = booking["user_email"].as_s.strip.downcase
      if booking_email != details.assigned_email
        booking_id = booking["id"].as_i64

        # this is an incorrect booking, we should delete it
        # then we can add the current assignment to missing
        staff_api.booking_delete(booking_id).get unless test

        deleted[booking_id] = booking_email
        missing[desk_id] = details
      end
    end

    # remove bookings that shouldn't exist
    removed_dangling = 0
    bookings.each do |booking|
      asset_id = booking["asset_id"].as_s
      if assignments[asset_id]?.nil?
        booking_id = booking["id"].as_i64
        booking_email = booking["user_email"].as_s.strip.downcase

        # this is an incorrect booking, we should delete it
        # then we can add the current assignment to missing
        staff_api.booking_delete(booking_id).get unless test

        removed_dangling += 1
        deleted[booking_id] = booking_email
      end
    end

    # log the results
    removed_log = String.build do |io|
      io << "found #{removed_dangling} dangling bookings\n" unless removed_dangling.zero?
      io << "checked #{assignments.size} assignments against #{bookings.size} bookings\n"
      io << "failed to remove #{failed} bookings\n" unless failed.zero?
      io << "removed #{deleted.size} incorrect assignments\n"
      deleted.each do |booking_id, email|
        io << "  - #{email}: #{booking_id}\n"
      end
      io << "found #{missing.size} missing assignments"
    end
    self["#{building_zone}-removed"] = removed_log
    logger.debug { removed_log }

    logger.debug { "creating missing bookings..." } unless missing.size.zero?

    # update the bookings with the new ids
    fixed = 0
    no_applied = [] of String
    missing.each do |desk_id, details|
      logger.debug { "  - assigning #{desk_id} => #{details.assigned_email}" }

      begin
        staff_api.create_booking(
          asset_id: desk_id,
          asset_ids: {desk_id},
          asset_name: details.desk_name,
          zones: parent_zones + [
            building_zone,
            details.level_zone,
          ],
          booking_start: booking_start.to_unix,
          booking_end: booking_end.to_unix,
          booking_type: "desk",
          time_zone: timezone.name,
          user_email: details.assigned_email,
          user_id: details.assigned_email,
          user_name: details.assigned_email,
          title: "Desk Booking",
          extension_data: {
            "asset_name"  => details.desk_name,
            "is_assigned" => true,
            "assets"      => [] of String,
            "tags"        => [] of String,
          },
          recurrence_type: "daily",
          recurrence_days: 127,
          limit_override: 1000,
        ).get unless test

        fixed += 1
      rescue error
        Log.warn { "    FAILED assigning #{desk_id} => #{details.assigned_email}" }
        no_applied << desk_id
      end
    end

    overview = String.build do |io|
      io << "added #{fixed} missing bookings\n" unless missing.size.zero?
      if !no_applied.size.zero?
        io << "failed to apply #{no_applied.size} bookings\n"
      end
    end
    self["#{building_zone}-added"] = overview
    logger.debug { overview }
  end
end
