require "placeos-driver"

class Zoom::RoomsApiSimple < PlaceOS::Driver
  descriptive_name "Zoom Rooms API Simple"
  generic_name :ZoomRoomsSimple
  uri_base "https://api.zoom.us/v2"

  default_settings({
    access_token: "your_access_token",
    room_id:      "optional_default_room_id",
  })

  def on_load
    on_update
  end

  def on_update
    @access_token = setting(String, :access_token)
    @default_room_id = setting?(String, :room_id)
  end

  @access_token : String = ""
  @default_room_id : String? = nil

  # List Zoom Rooms
  def list_rooms
    response = get("/rooms", headers: {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type"  => "application/json",
    })

    if response.success?
      data = JSON.parse(response.body)
      self[:rooms] = data["rooms"]
      data
    else
      raise "API request failed: #{response.status_code}"
    end
  end
end