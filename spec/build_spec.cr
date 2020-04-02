require "./spec_helper"

module PlaceOS::Drivers::Api
  describe Build do
    with_server do
      it "should list drivers" do
        result = curl("GET", "/build")
        drivers = Array(String).from_json(result.body)
        (drivers.size > 0).should be_true
        drivers.includes?("drivers/place/spec_helper.cr").should be_true
      end

      it "should build a driver" do
        result = curl("POST", "/build?driver=drivers/place/spec_helper.cr")
        result.status_code.should eq(201)
      end

      it "should list compiled versions" do
        result = curl("GET", "/build/drivers%2Fplace%2Fspec_helper.cr/")
        result.status_code.should eq(200)
        drivers = Array(String).from_json(result.body)
        drivers[0].starts_with?("drivers_place_spec_helper_").should be_true
      end

      it "should list possible versions" do
        result = curl("GET", "/build/drivers%2Fplace%2Fspec_helper.cr/commits")

        result.status_code.should eq(200)
        commits = JSON.parse(result.body)
        commits.size.should eq(1)
      end

      it "should delete all compiled versions of a driver" do
        result = curl("DELETE", "/build/drivers%2Fplace%2Fspec_helper.cr/")
        result.status_code.should eq(200)

        result = curl("GET", "/build/drivers%2Fplace%2Fspec_helper.cr/")
        result.status_code.should eq(200)
        drivers = Array(String).from_json(result.body)
        drivers.size.should eq(0)
      end
    end
  end
end
