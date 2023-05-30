require "placeos-driver/spec"

DriverSpecs.mock_driver "KontaktIO::ContactTracing" do
  system({
    KontaktIO:        {KontaktIOMock},
    LocationServices: {LocationServicesMock},
  })

  report = exec(:close_contacts, "steve@place.tech", "stakach").get
  report.should eq([
    {
      "mac_address"  => "00fab603c01b",
      "username"     => "jmcfar",
      "contact_time" => 1645761763,
      "duration"     => 7662,
    }, {
      "mac_address"  => "00fab603c01e",
      "username"     => "jwest",
      "contact_time" => 1645761763,
      "duration"     => 2386,
    },
  ])
end

# :nodoc:
class KontaktIOMock < DriverSpecs::MockDriver
  def colocations(mac_address : String, start_time : Int64? = nil, end_time : Int64? = nil)
    JSON.parse %([
      {
            "trackingId": "00:fa:b6:03:c0:1b",
            "startTime": "2022-02-25T04:02:43Z",
            "endTime": "2022-03-02T04:02:43Z",
            "contacts": [
                {
                    "trackingId": "00:fa:b6:02:4b:a3",
                    "durationSec": 7662
                }
            ]
        },
        {
            "trackingId": "00:fa:b6:03:c0:1e",
            "startTime": "2022-02-25T04:02:43Z",
            "endTime": "2022-03-02T04:02:43Z",
            "contacts": [
                {
                    "trackingId": "00:fa:b6:02:4b:a3",
                    "durationSec": 2386
                }
            ]
        }
    ])
  end
end

# :nodoc:
class LocationServicesMock < DriverSpecs::MockDriver
  def macs_assigned_to(email : String? = nil, username : String? = nil)
    ["00fab6024ba3"]
  end

  def check_ownership_of(mac_address : String)
    case mac_address
    when "00fab603c01b"
      {location: "wireless", assigned_to: "jmcfar", mac_address: "00fab603c01b"}
    when "00fab603c01e"
      {location: "wireless", assigned_to: "jwest", mac_address: "00fab603c01e"}
    else
      nil
    end
  end
end
