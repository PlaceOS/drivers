require "./spec_helper"

class Dummy
  include EngineDrivers::Helper
end

describe EngineDrivers::Helper, focus: true do
  dummy = Dummy.new
  it "should list drivers" do
    drivers = dummy.drivers("private_drivers")
    (drivers.size > 0).should eq(true)
    drivers.includes?("drivers/aca/private_helper.cr").should eq(true)
  end

  it "should build a driver" do
    commits = dummy.commits("drivers/aca/private_helper.cr", "private_drivers")
    commit = commits[0][:commit]
    result = dummy.compile_driver("drivers/aca/private_helper.cr", "private_drivers", commit)
    result[:exit_status].should eq(0)
    # "/Users/steve/Documents/projects/crystal-engine/crystal-engine-drivers/bin/drivers/drivers_aca_private_helper_cr_4f6e0cd"
    result[:executable].ends_with?("/drivers_aca_private_helper_cr_4f6e0cd").should eq(true)
  end
end
