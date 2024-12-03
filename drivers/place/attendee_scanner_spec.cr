require "placeos-driver/spec"

# :nodoc:
class LocationServices < DriverSpecs::MockDriver
  def on_load
    self[:building_id_requested] = false
  end

  def building_id
    self[:building_id_requested] = true
    "zone-building"
  end

  def systems
    self[:systems_requested] = true
    {
      "zone-level1": [
        "spec_runner_system",
      ],
    }
  end
end

# :nodoc:
class StaffAPI < DriverSpecs::MockDriver
  def zone(zone_id : String)
    raise "unexpected zone requested #{zone_id}" unless zone_id == "zone-building"

    {
      id:        "zone-building",
      timezone:  "Australia/Sydney",
      parent_id: "zone-org",
    }
  end

  def get_system(id : String, complete : Bool = false)
    raise "unexpected system requested #{id}" unless id == "spec_runner_system"

    {
      name: "Test Room 1",
    }
  end

  def query_bookings(
    type : String? = nil,
    period_start : Int64? = nil,
    period_end : Int64? = nil,
    zones : Array(String) = [] of String,
    user : String? = nil,
    email : String? = nil,
    state : String? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    created_before : Int64? = nil,
    created_after : Int64? = nil,
    approved : Bool? = nil,
    rejected : Bool? = nil,
    checked_in : Bool? = nil,
    include_checked_out : Bool? = nil,
    extension_data : JSON::Any? = nil
  )
    [] of Nil
  end

  def create_booking(
    booking_type : String,
    asset_id : String,
    user_id : String,
    user_email : String,
    user_name : String,
    zones : Array(String),
    booking_start : Int64? = nil,
    booking_end : Int64? = nil,
    checked_in : Bool = false,
    approved : Bool? = nil,
    title : String? = nil,
    description : String? = nil,
    time_zone : String? = nil,
    extension_data : JSON::Any? = nil,
    utm_source : String? = nil,
    limit_override : Int64? = nil,
    event_id : String? = nil,
    ical_uid : String? = nil,
    attendees : Array(JSON::Any)? = nil
  )
    true
  end
end

# :nodoc:
class Bookings < DriverSpecs::MockDriver
  def on_load
    self[:bookings] = [{
      "event_start": 1.hour.ago.to_unix,
      "event_end":   1.hour.from_now.to_unix,
      "id":          "AAkALgAAAAAAHYQDEapmEc2byACqAC-EWg0AVrOjSWJ0R0_lv6HqEl72fQABnPXAjwAA",
      "host":        "IsaiahL@comment.out",
      "title":       "Test Meeting",
      "body":        "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\r\n<meta name=\"Generator\" content=\"Microsoft Exchange Server\">\r\n<!-- converted from text -->\r\n<style><!-- .EmailQuote { margin-left: 1pt; padding-left: 4pt; border-left: #800000 2px solid; } --></style></head>\r\n<body>\r\n<font size=\"2\"><span style=\"font-size:11pt;\"><div class=\"PlainText\">&nbsp;</div></span></font>\r\n</body>\r\n</html>\r\n",
      "attendees":   [
        {
          "name":            "Isaiah Langer",
          "email":           "isaiahl@comment.out",
          "response_status": "needsAction",
          "resource":        false,
        },
        {
          "name":            "steve@vontaka.ch",
          "email":           "steve@vontaka.ch",
          "response_status": "needsAction",
          "resource":        false,
        },
        {
          "name":            "Test Room 1",
          "email":           "testroom1@comment.out",
          "response_status": "accepted",
          "resource":        true,
        },
      ],
      "hide_attendees":          false,
      "location":                "Test Room 1",
      "private":                 false,
      "all_day":                 false,
      "timezone":                "Australia/Sydney",
      "recurring":               false,
      "created":                 "2024-12-03T08:59:00Z",
      "updated":                 "2024-12-03T08:59:56Z",
      "attachments":             [] of Nil,
      "status":                  "confirmed",
      "creator":                 "IsaiahL@comment.out",
      "ical_uid":                "040000008200E00074C5B7101A82E00800000000B5C273946145DB01000000000000000010000000651007D546B31E4EB651ED0F73A0CDB6",
      "online_meeting_provider": "teamsForBusiness",
      "online_meeting_phones":   [] of Nil,
      "online_meeting_url":      "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZjRkMTM2ZTYtZGIxNi00NDFkLWI5NGYtNDA3Mjg1NDg0YzA2%40thread.v2/0?context=%7b%22Tid%22%3a%22bc9d5ad8-7518-422b-ac8d-b69429ca4cb9%22%2c%22Oid%22%3a%22905b5cbc-ac57-4159-98a7-9b9d8e%22%7d",
      "mailbox":                 "testroom1@comment.out",
    }]
  end
end

DriverSpecs.mock_driver "Place::AttendeeScanner" do
  system({
    StaffAPI:         {StaffAPI},
    LocationServices: {LocationServices},
    Bookings:         {Bookings},
  })

  resp = exec(:invite_external_guests).get
  resp.should eq({
    "invited" => 1,
    "checked" => 1,
    "failure" => 0,
  })
end
