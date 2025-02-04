require "json"

class Place::Locker
  include JSON::Serializable

  getter id : String
  getter name : String { id }
  getter bank_id : String
  getter bookable : Bool { false }

  # for tracking, not part of metadata
  property level_id : String? = nil
end

class Place::LockerBank
  include JSON::Serializable

  getter id : String
  getter name : String { id }
  getter zones : Array(String)

  # for tracking, not part of metadata
  property level_id : String? = nil
  getter lockers : Array(Locker) = [] of Locker
  getter locker_hash : Hash(String, Locker) do
    lookup = {} of String => Locker
    level = self.level_id
    lockers.each do |locker|
      locker.level_id = level
      lookup[locker.id] = locker
    end
    lookup
  end
end

module Place::LockerMetadataParser
  getter locker_banks : Hash(String, LockerBank) do
    # Grab bank details
    banks = staff_api.metadata(building_id, "locker_banks").get.dig?("locker_banks", "details")
    return Hash(String, LockerBank).new unless banks

    banks = begin
      Array(LockerBank).from_json(banks.to_json)
    rescue error
      message = "error parsing banks json on building #{building_id}:\n#{banks.to_pretty_json}"
      logger.warn(exception: error) { message }
      raise message
    end

    lookup = {} of String => LockerBank
    banks.each do |bank|
      bank.level_id = (levels & bank.zones).first?
      lookup[bank.id] = bank
    end

    # Grab locker details:
    lockers = staff_api.metadata(building_id, "lockers").get.dig?("lockers", "details")
    return lookup unless lockers

    lockers = begin
      Array(Locker).from_json(lockers.to_json)
    rescue error
      message = "error parsing locker json on building #{building_id}:\n#{lockers.to_pretty_json}"
      logger.warn(exception: error) { message }
      raise message
    end

    lockers.each do |locker|
      begin
        bank = lookup[locker.bank_id]
        locker.level_id = bank.level_id
        bank.lockers << locker
      rescue error
        logger.warn(exception: error) { "config issue with locker #{locker.id} on bank #{locker.bank_id}" }
      end
    end

    lookup
  end

  getter locker_details : Hash(String, Locker) do
    lockers = {} of String => Locker
    locker_banks.each_value do |bank|
      bank.lockers.each do |locker|
        lockers[locker.id] = locker
      end
    end
    lockers
  end
end
