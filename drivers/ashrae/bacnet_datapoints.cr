require "placeos-driver"
require "json"

class Ashrae::BACnetDataPoints < PlaceOS::Driver
  descriptive_name "BACnet Data Points"
  generic_name :DataPoints

  default_settings({
    points: {
      "power"    => "101003.AnalogValue[45]",
      "humidity" => "101005.AnalogValue[4]",
    },
  })

  accessor bacnet : BACnet_1

  def on_update
    subscriptions.clear
    points = setting(Hash(String, String), :points)
    points.each do |(key, status)|
      bacnet.subscribe(status) do |_sub, payload|
        self[key] = JSON.parse(payload)
      end
    end
  end
end
