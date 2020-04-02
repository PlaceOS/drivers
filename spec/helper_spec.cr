require "./spec_helper"

module PlaceOS::Drivers
  describe Helper do
    it "should list drivers" do
      drivers = Helper.drivers("private_drivers")
      (drivers.size > 0).should be_true
      drivers.includes?("drivers/place/private_helper.cr").should be_true
    end

    it "should build a driver" do
      commits = Helper.commits("drivers/place/private_helper.cr", "private_drivers")
      commit = commits[0][:commit]
      result = Helper.compile_driver("drivers/place/private_helper.cr", "private_drivers", commit)
      result[:exit_status].should eq(0)
      result[:executable].ends_with?("/drivers_place_private_helper_#{commit}").should be_true
    end
  end
end
