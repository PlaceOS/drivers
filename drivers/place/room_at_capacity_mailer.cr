require "placeos-driver"
require "placeos-driver/interface/mailer"
require "placeos-driver/interface/mailer_templates"

class Place::RoomAtCapacityMailer < PlaceOS::Driver
  include PlaceOS::Driver::Interface::MailerTemplates

  descriptive_name "PlaceOS Room at capacity mailer"
  generic_name :RoomAtCapacityMailer
  description %(notifies when a room is at capacity)

  default_settings({
    notify_email:                  ["concierge@place.com"],
    email_template:                "room_at_capacity",
    debounce_time_minutes:         60, # the time to wait before sending another email
    check_every_minutes:           5,  # the frequency to check rooms
    over_capactity_detected_count: 2,  # the number of times over capacity before sending an email
  })

  accessor staff_api : StaffAPI_1
  accessor locations : LocationServices_1

  def mailer
    system.implementing(Interface::Mailer)[0]
  end

  getter building_id : String do
    locations.building_id.get.as_s
  end

  # Grabs the list of systems in the building
  getter systems : Hash(String, Array(String)) do
    staff_api.systems_in_building(building_id).get.as_h.transform_values(&.as_a.map(&.as_s))
  end

  def on_load
    on_update
  end

  @notify_email : Array(String) = [] of String
  @email_template : String = "room_at_capacity"
  @debounce_time_minutes : Int32 = 60
  @over_capactity_detected_count : Int32 = 2

  @last_email_sent : Hash(String, Time) = {} of String => Time
  @over_capacity : Hash(String, Int32) = Hash(String, Int32).new { |hash, sys_id| hash[sys_id] = 0 }

  def on_update
    @building_id = nil
    @systems = nil

    @notify_email = setting?(Array(String), :notify_email) || [] of String
    @email_template = setting?(String, :email_template) || "room_at_capacity"
    @debounce_time_minutes = setting?(Int32, :debounce_time_minutes) || 60
    @over_capactity_detected_count = setting?(Int32, :over_capactity_detected_count) || 2

    period = setting?(Int32, :check_every_minutes) || 5
    schedule.clear
    schedule.every(period.minutes) { check_capacity }
  end

  def check_capacity
    systems.each do |level_id, system_ids|
      system_ids.each do |system_id|
        sys = system(system_id)
        next unless sys.exists?("Bookings", 1)
        next unless sys.capacity > 0

        if people_count = sys.get("Bookings", 1).status?(Float64, "people_count")
          logger.debug { "people count for #{system_id}: #{people_count}" }

          if people_count >= sys.capacity
            @over_capacity[system_id] += 1
          else
            @over_capacity[system_id] = 0
          end

          if (over = @over_capacity[system_id]?) && over == @over_capactity_detected_count
            send_email(
              sys.capacity,
              people_count,
              system_id,
              sys.name,
              sys.display_name,
              sys.description,
              sys.email,
            )
          end
        end
      end
    end
  end

  @[Security(Level::Support)]
  def send_email(
    capacity : Int32,
    people_count : Float64,
    system_id : String,
    name : String? = nil,
    display_name : String? = nil,
    description : String? = nil,
    system_email : String? = nil,
  )
    if (last = @last_email_sent[system_id]?) && Time.utc - last < @debounce_time_minutes.minutes
      logger.debug { "skipping email for #{system_id} due to debounce timer" }
      return
    end

    args = {
      system_id:    system_id,
      name:         name,
      display_name: display_name,
      description:  description,
      system_email: system_email,
      capacity:     capacity,
      people_count: people_count,
    }

    begin
      mailer.send_template(
        to: @notify_email,
        template: {"room_at_capacity", @email_template},
        args: args)
      @last_email_sent[system_id] = Time.utc
    rescue error
      logger.warn(exception: error) { "failed to send at capacity email for zone #{system_id}" }
    end
  end

  def template_fields : Array(TemplateFields)
    [
      TemplateFields.new(
        trigger: {"room_at_capacity", @email_template},
        name: "Room at capacity",
        description: "Notification when a room is at capacity",
        fields: [
          {name: "system_id", description: "Identifier of the room/system"},
          {name: "name", description: "Room name"},
          {name: "display_name", description: "Room display name"},
          {name: "description", description: "Room description"},
          {name: "system_email", description: "System/room email address"},
          {name: "capacity", description: "Capacity of the room"},
          {name: "people_count", description: "Number of people in the room"},
        ]
      ),
    ]
  end
end
