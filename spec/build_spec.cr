require "./spec_helper"

describe Build do
  with_server do
    it "should list drivers" do
      result = curl("GET", "/build")
      drivers = Array(String).from_json(result.body)
      (drivers.size > 0).should eq(true)
      drivers.includes?("drivers/aca/spec_helper.cr").should eq(true)
    end

    it "should build a driver" do
      result = curl("POST", "/build?driver=drivers/aca/spec_helper.cr")
      result.status_code.should eq(201)
    end

    it "should list a driver" do
      result = curl("GET", "/build/drivers%2Faca%2Fspec_helper.cr/")
      result.status_code.should eq(200)
      drivers = Array(String).from_json(result.body)
      drivers[0].starts_with?("drivers_aca_spec_helper_cr_").should eq(true)
    end
  end
end
