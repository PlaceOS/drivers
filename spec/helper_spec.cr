require "./spec_helper"

describe EngineDrivers::Helper do
  it "should list drivers" do
    helper = EngineDrivers::Helper.new
    drivers = helper.drivers("private_drivers")
    (drivers.size > 0).should eq(true)
    drivers.includes?("drivers/aca/private_helper.cr").should eq(true)
  end

  it "should build a driver" do
    helper = EngineDrivers::Helper.new
    commits = helper.commits("drivers/aca/private_helper.cr", "private_drivers")
    commit = commits[0][:commit]
    result = helper.compile_driver("drivers/aca/private_helper.cr", "private_drivers", commit)
    result[:exit_status].should eq(0)
    # "/Users/steve/Documents/projects/crystal-engine/crystal-engine-drivers/bin/drivers/drivers_aca_private_helper_cr_4f6e0cd"
    result[:executable].ends_with?("/drivers_aca_private_helper_cr_4f6e0cd").should eq(true)
  end
end
