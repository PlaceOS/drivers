require "./spec_helper"

describe Build do
  with_server do
    it "should list drivers" do
      result = curl("GET", "/build")
      drivers = Array(String).from_json(result.body)
      (drivers.size > 0).should eq(true)
      drivers.includes?("drivers/aca/spec_helper.cr").should eq(true)
    end
  end
end
