DriverSpecs.mock_driver "XYSense::LocationService" do
  system({
    StaffAPI: {StaffAPI},
    FindMe:   {FindMe},
  })

  now = Time.local
  start = now.at_beginning_of_day.to_unix
  ending = now.at_end_of_day.to_unix

  exec(:query_desk_bookings).get
  resp = exec(:device_locations, "zone-id").get
  puts resp
  resp.should eq([
    {
      "location"         => "wireless",
      "coordinates_from" => "top-left",
      "x"                => 76.0,
      "y"                => 29.0,
      "map_width"        => 100,
      "lon"              => 151.1382508278,
      "lat"              => -33.796597429,
      "s2_cell_id"       => "6b12a5f8f0c4",
      "mac"              => "dwatson",
      "variance"         => 0.0,
      "last_seen"        => 1447295150,
      "level"            => "zone-id",
      "building"         => "zone-building",
      "findme_building"  => "SYDNEY",
      "findme_level"     => "L14",
      "findme_status"    => "Located",
      "findme_type"      => "Person",
    }, {
      "location"        => "desk",
      "at_location"     => true,
      "map_id"          => "table-11.097",
      "level"           => "zone-id",
      "building"        => "zone-building",
      "mac"             => "acorder003",
      "last_seen"       => 1608185586,
      "findme_building" => "SYDNEY",
      "findme_level"    => "L14",
      "findme_status"   => "NoRecentData",
      "findme_type"     => "Person",
      "booking_start"   => start,
      "booking_end"     => ending,
      "booked_for"      => "zdoo@org.com",
    }, {
      "location"      => "desk",
      "at_location"   => false,
      "map_id"        => "table-123",
      "level"         => "zone-id",
      "building"      => "zone-building",
      "mac"           => "user-1234",
      "booking_start" => start,
      "booking_end"   => ending,
    },
  ])
end

class FindMe < DriverSpecs::MockDriver
  def user_details(usernames : String | Array(String))
    JSON.parse %([{"Alias":"dwatson","LastUpdate":"2015-11-12T02:25:50.017Z","Confidence":100,
       "Coordinates":{"Building":"SYDNEY","Level":"L14","X":76,"Y":29,"LocationDescription":"2140","MapByLocationId":true},
       "GPS":{"Latitude":-33.796597429,"Longitude":151.1382508278,"Accuracy":0.0,"LocationDescription":null},
       "LocationIdentifier":null,"Status":"Located","LocatedUsing":"FixedLocation","Type":"Person","Comments":null,
       "ExtendedUserData":{"Alias":"dwatson","DisplayName":"David Watson","EmailAddress":"David.Watson@microsoft.com","LyncSipAddress":"dwatson@microsoft.com"}}])
  end

  def users_on(building : String, level : String)
    # Wireless and a desk
    JSON.parse %([{"Alias":"dwatson","LastUpdate":"2015-11-12T02:25:50.017Z","Confidence":100,
       "Coordinates":{"Building":"SYDNEY","Level":"L14","X":76,"Y":29,"LocationDescription":"2140","MapByLocationId":true},
       "GPS":{"Latitude":-33.796597429,"Longitude":151.1382508278,"Accuracy":0.0,"LocationDescription":null},
       "LocationIdentifier":null,"Status":"Located","LocatedUsing":"WiFi","Type":"Person","Comments":null,
       "ExtendedUserData":{"Alias":"dwatson","DisplayName":"David Watson","EmailAddress":"David.Watson@microsoft.com","LyncSipAddress":"dwatson@microsoft.com"}},

           {
              "Alias": "acorder003",
              "LastUpdate": "2020-12-17T06:13:06.797Z",
              "CurrentUntil": "2020-12-17T06:16:06.797Z",
              "Confidence": 100,
              "Coordinates": null,
              "GPS": null,
              "LocationIdentifier": "11.097",
              "Status": "NoRecentData",
              "LocatedUsing": "FixedLocation",
              "Type": "Person",
              "Comments": null,
              "ExtendedUserData": null,
              "WiFiScale": 1.00,
              "userTypes": []
          }
       ])
  end
end

class StaffAPI < DriverSpecs::MockDriver
  def query_bookings(type : String, zones : Array(String))
    logger.debug { "Querying desk bookings!" }

    now = Time.local
    start = now.at_beginning_of_day.to_unix
    ending = now.at_end_of_day.to_unix
    [{
      id:            1,
      booking_type:  type,
      booking_start: start,
      booking_end:   ending,
      asset_id:      "table-123",
      user_id:       "user-1234",
      user_email:    "user1234@org.com",
      user_name:     "Bob Jane",
      zones:         zones + ["zone-building"],
      checked_in:    true,
      rejected:      false,
    },
    {
      id:            2,
      booking_type:  type,
      booking_start: start,
      booking_end:   ending,
      asset_id:      "table-11.097",
      user_id:       "user-456",
      user_email:    "zdoo@org.com",
      user_name:     "Zee Doo",
      zones:         zones + ["zone-building"],
      checked_in:    false,
      rejected:      false,
    }]
  end

  def zone(zone_id : String)
    logger.info { "requesting zone #{zone_id}" }

    if zone_id == "placeos-zone-id"
      {
        id:   zone_id,
        tags: ["level"],
      }
    else
      {
        id:   zone_id,
        tags: ["building"],
      }
    end
  end
end
