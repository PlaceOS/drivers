require "placeos-driver"

class Zoom::TestSimple < PlaceOS::Driver
  descriptive_name "Zoom Test Simple"
  generic_name :ZoomTestSimple

  def on_load
    logger.info { "Driver loaded" }
  end

  def test_method
    logger.info { "Test method called" }
    "success"
  end
end