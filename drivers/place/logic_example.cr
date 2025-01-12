require "placeos-driver"

# use for testing some basic functionality
class Place::LogicExample < PlaceOS::Driver
  descriptive_name "Example Logic"
  generic_name :ExampleLogic

  accessor main_lcd : Display_1

  def on_update
    logger.info { "woot! an update #{setting?(String, :name)}" }
  end

  def power_state?
    main_lcd[:power]
  end

  def power(state : Bool)
    system.all(:Display).power(state)
  end

  def display_count
    system.count(:Display)
  end

  def not_implemented
    raise "not implemented"
  end
end
