require "json"
require "./health_rooms_models"

module Place::Chat
  # room defaults are at: settings -> notifications
  # Metadata stored on the user model:
  # notifications = {
  #   general   => NotificationSettings, (defaults)
  #   system_id => NotificationSettings  (per-room override)
  # }

  struct NotifyEventSettings
    include JSON::Serializable

    def initialize
    end

    getter? enabled : Bool = true
    getter? browser : Bool = true
    getter? email : Bool = true
    getter? sms : Bool = true

    # minutes before notification
    getter delay : Int32 = 3
  end

  struct NotificationSettings
    include JSON::Serializable

    def initialize
    end

    # only alert if the user selected me
    getter? chosen_provider : Bool = false
    getter? enabled : Bool = true

    getter on_enter : NotifyEventSettings = NotifyEventSettings.new
    # how often should it send notifications
    getter on_recurr : NotifyEventSettings = NotifyEventSettings.new
    # do we only notify if the user has been waiting for a certain amount of time
    getter on_waiting : NotifyEventSettings = NotifyEventSettings.new
    # settings if the patient has been waiting for a long time
    getter on_escalate : NotifyEventSettings = NotifyEventSettings.new
  end

  class RoomMember
    include JSON::Serializable

    getter? available : Bool
    property email : String
    getter id : String
    property name : String
    property phone : String?
    getter roles : Array(String)

    @[JSON::Field(ignore: true)]
    property! notifications : NotificationSettings

    def coordinator?
      roles.includes? "coordinator"
    end

    def clinician?
      roles.includes? "clinician"
    end

    def admin?
      roles.includes? "admin"
    end
  end

  struct OpeningHours
    def initialize(opening_times : Tuple(String, String, Bool))
      @opens = parse_time opening_times[0]
      @closes = parse_time opening_times[1]
      @enabled = opening_times[2]
    end

    protected def parse_time(time : String)
      hours, minutes = time.split(':').map(&.strip)
      hours.to_i.hours + minutes.to_i.minutes
    end

    getter opens : Time::Span
    getter closes : Time::Span
    getter enabled : Bool

    def is_open?(now : Time)
      return false unless enabled
      start_of_day = now.at_beginning_of_day
      opening = start_of_day + opens
      return false unless now >= opening
      closing = start_of_day + closes
      now < closing
    end
  end

  # Room metadata => settings key
  class RoomSettings
    include JSON::Serializable

    def initialize
    end

    getter available : Bool = true
    getter open_24_7 : Bool = true
    getter notifications : NotificationSettings do
      NotificationSettings.new
    end

    property members : Array(RoomMember) = [] of RoomMember

    @[JSON::Field(ignore: true)]
    property! timezone : Time::Location

    # 0 index == Monday
    #   open time, close time, enabled
    getter opening_hours : Array(Tuple(String, String, Bool)) do
      [] of Tuple(String, String, Bool)
    end

    @[JSON::Field(ignore: true)]
    getter opening : Hash(Time::DayOfWeek, OpeningHours) do
      times = {} of Time::DayOfWeek => OpeningHours
      opening_hours.each_with_index do |times, index|
        index += 1
        times[Time::DayOfWeek.from_value(index)] = OpeningHours.new(times)
      end
      times
    end

    def is_open?(timezone : Time::Location)
      return false unless available
      return true if open_24_7
      now = Time.local timezone

      # more efficient version of
      # opening[now.day_of_week].is_open? now
      index = now.day_of_week.to_i - 1
      OpeningHours.new(opening_hours[index]).is_open? now
    end
  end
end
