require "placeos-driver"

class ZoomRoomsApiTest < PlaceOS::Driver
  descriptive_name "Zoom Rooms API Test"
  generic_name :ZoomRoomsTest
  uri_base "https://api.zoom.us/v2"

  default_settings({
    access_token: "your_access_token",
  })

  def on_load
    logger.info { "Driver loaded" }
  end

  def test_method
    "success"
  end
end