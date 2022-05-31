require "./scanning_api"
require "placeos-driver/spec"

# :nodoc:
class DashboardMock < DriverSpecs::MockDriver
  def fetch(location : String)
    logger.info { "fetching: #{location}" }
    case location
    when "/api/v1/networks/network_id/floorPlans"
      %([{"floorPlanId":"floor-123","name":"Level 1","width":30.5,"height":20,"topLeftCorner":{"lat":0,"lng":0},"bottomLeftCorner":{"lat":0,"lng":0},"bottomRightCorner":{"lat":0,"lng":0}}])
    when "/api/v1/networks/network_id/devices"
      %([])
    when "/api/v1/devices/Q2HV-KAM-ETSG/camera/analytics/live"
      %({
          "ts": "2021-08-09T23:56:52.236Z",
          "zones": {
              "582653201791058186": {
                  "person": 0
              },
              "582653201791058185": {
                  "person": 0
              },
              "0": {
                  "person": 0
              }
          }
      })
    else
      %([])
    end
  end

  def fetch_all(location : String)
    [fetch(location)]
  end
end

DriverSpecs.mock_driver "Cisco::Meraki::Locations" do
  system({
    Dashboard: {DashboardMock},
  })

  sleep 0.5

  # Should standardise the format of MAC addresses
  exec(:format_mac, "0x12:34:A6-789B").get.should eq %(1234a6789b)

  floors_raw = %({"g_727894289773756676": {
      "floorPlanId": "g_727894289773756676",
      "width": 84.73653902424,
      "height": 55.321510873304,
      "topLeftCorner": {
          "lat": 25.20105494120424,
          "lng": 55.27527794417147
      },
      "bottomLeftCorner": {
          "lat": 25.20128402691947,
          "lng": 55.27478983574903
      },
      "bottomRightCorner": {
          "lat": 25.200607564298647,
          "lng": 55.27440203743774
      },
      "name": "BUILDING - L3"
  },
  "g_727894289773756679": {
      "floorPlanId": "g_727894289773756679",
      "width": 82.037895885132,
      "height": 48.035263155936,
      "topLeftCorner": {
          "lat": 25.201070920997147,
          "lng": 55.27523029269689
      },
      "bottomLeftCorner": {
          "lat": 25.20126383588677,
          "lng": 55.274803104166594
      },
      "bottomRightCorner": {
          "lat": 25.200603702563107,
          "lng": 55.27443896882145
      },
      "name": "Building - GF"
  }})
  floors = Hash(String, Cisco::Meraki::FloorPlan).from_json(floors_raw)

  macs_raw = %({"683a1e545b0c": {
      "floorPlanId": "g_727894289773756676",
      "lat": 25.2011012305148,
      "lng": 55.2749184519053,
      "mac": "68:3a:1e:54:5b:0c",
      "name": "1F-07",
      "model": "MV22",
      "firmware": "camera-4-13",
      "serial": "Q2HV-KAM-ETSG"
  },
  "683a1e5474ed": {
      "floorPlanId": "g_727894289773756679",
      "lat": 25.2008175846893,
      "lng": 55.2746475487948,
      "mac": "68:3a:1e:54:74:ed",
      "name": "GF-29",
      "model": "MV22",
      "firmware": "camera-4-13",
      "serial": "Q2HV-KAM-ETSG"
  }})
  macs = Hash(String, Cisco::Meraki::NetworkDevice).from_json(macs_raw)

  macs.each do |_mac, wap_device|
    floor_plan = floors[wap_device.floor_plan_id]
    # do some unit testing
    loc = Cisco::Meraki::DeviceLocation.calculate_location(floor_plan, wap_device, Time.utc)
    pp! loc
    loc.to_json
  end

  exec(:camera_analytics, "Q2HV-KAM-ETSG").get.should eq({
    "ts"    => "2021-08-09T23:56:52.236+0000",
    "zones" => {
      "582653201791058186" => {"person" => 0},
      "582653201791058185" => {"person" => 0},
      "0"                  => {"person" => 0},
    },
  })
end
