require "json"
require "faker"
require "placeos-driver"
require "placeos-driver/interface/door_security"

class Rhombus::SecurityMock < PlaceOS::Driver
  descriptive_name "Rhombus Mock Security System"
  generic_name :SecurityMock
  description %(a mock security system for interface testing)

  include PlaceOS::Driver::Interface::DoorSecurity

  default_settings({
    door_list_size:    30,
    swipe_event_every: 30,
  })

  def on_load
    on_update
  end

  record CardUser, card_id : String, user_name : String, user_email : String do
    include JSON::Serializable
  end

  getter door_list : Array(Door) = [] of Door
  getter card_holders : Array(CardUser) = [] of CardUser

  def on_update
    # ensure door names and IDs don't change between reloads
    door_list_size = setting?(Int32, :door_list_size) || 30
    Faker.seed door_list_size

    doors = Array(Door).new(door_list_size)
    door_list_size.times do
      doors << Door.new(
        Faker::Business.credit_card_number,
        Faker::Commerce.department
      )
    end
    @door_list = doors

    # generate some card holders
    @card_holders = (0..10).map do
      CardUser.new(
        Faker::Business.credit_card_number,
        Faker::Name.name,
        Faker::Internet.safe_email
      )
    end

    # Trigger regular swipe events
    swipe_event_period = setting?(Int32, :swipe_event_every) || 30
    schedule.clear
    schedule.every(swipe_event_period.seconds) do
      door = doors.sample
      action = Action::Granted

      case rand(6)
      when 0, 1, 2
        user = card_holders.sample
      when 3
        action = Action::Denied
        user = card_holders.sample
      when 4
        action = Action::Tamper
      when 5
        action = Action::RequestToExit
      end

      publish("security/event/door", DoorEvent.new(
        module_id: module_id,
        security_system: "mock",
        door_id: door.door_id,
        action: action,
        card_id: user.try &.card_id,
        user_name: user.try &.user_name,
        user_email: user.try &.user_email
      ).to_json)
    end
  end

  def unlock(door_id : String) : Bool?
    self[:last_unlocked] = door_id
    true
  end
end
