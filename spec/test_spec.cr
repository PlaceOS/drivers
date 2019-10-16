require "./spec_helper"

module ACAEngine::Drivers::Api
  describe Test do
    with_server do
      it "should list drivers" do
        result = curl("GET", "/test?repository=private_drivers")
        drivers = Array(String).from_json(result.body)
        (drivers.size > 0).should eq(true)
        drivers.includes?("drivers/aca/private_helper_spec.cr").should eq(true)
      end

      it "should build a driver" do
        result = curl("POST", "/test?repository=private_drivers&driver=drivers/aca/private_helper.cr&spec=drivers/aca/private_helper_spec.cr")
        result.status_code.should eq(200)
      end
    end
  end
end
