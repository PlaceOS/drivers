require "placeos-driver"
class VisitorEntry < PlaceOS::Driver
    generic_name :VisitorEntry
    descriptive_name "Do things when visitors enter"
    description "Links devices and services with access control events"
    
    # Hook into access control listener
    bind Access_1, :last_event, :last_event_changed

    def get_last_event
        logger.debug system[:Access_1][:last_event]
    end
  end