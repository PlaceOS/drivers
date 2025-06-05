require "placeos-driver"

class Zoom::RoomsApiMinimal < PlaceOS::Driver
  descriptive_name "Zoom Rooms API Minimal"
  generic_name :ZoomRoomsMinimal
  
  uri_base "https://api.zoom.us/v2"

  default_settings({
    account_id:    "your_account_id",
    client_id:     "your_client_id",
    client_secret: "your_client_secret",
  })

  def on_load
    on_update
  end

  def on_update
    @account_id = setting(String, :account_id)
    @client_id = setting(String, :client_id)
    @client_secret = setting(String, :client_secret)
  end

  @account_id : String = ""
  @client_id : String = ""
  @client_secret : String = ""

  def test_method
    "test"
  end
end