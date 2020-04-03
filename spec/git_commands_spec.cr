require "./spec_helper"
require "yaml"

module PlaceOS::Drivers
  describe GitCommands do
    private_drivers = Helper.get_repository_path("private_drivers")
    private_readme = File.join(private_drivers, "README.md")
    current_title = "# Private PlaceOS Drivers\n"
    old_title = "# Private Engine Drivers\n"

    it "should list files in the repository" do
      files = PlaceOS::Drivers::GitCommands.ls
      (files.size > 0).should be_true
      files.includes?("shard.yml").should be_true
    end

    it "should list the revisions to a file in a repository" do
      changes = GitCommands.commits("shard.yml", 200, private_drivers)
      (changes.size > 0).should be_true
      changes.map { |commit| commit[:subject] }.includes?("simplify dependencies").should be_true
    end

    it "should list the revisions of a repository" do
      changes = PlaceOS::Drivers::GitCommands.repository_commits(private_drivers, 200)
      (changes.size > 0).should be_true
      changes.map { |commit| commit[:subject] }.includes?("simplify dependencies").should be_true
    end

    it "should checkout a particular revision of a file and then restore it" do
      # Check the current file
      title = File.open(private_readme) { |file| file.gets('\n') }
      title.should eq(current_title)

      # Process a particular commit
      PlaceOS::Drivers::GitCommands.checkout("README.md", "0bcfa6e4a9ad832fadf799f15f269608d61086a7", private_drivers) do
        title = File.open(private_readme) { |file| file.gets('\n') }
        title.should eq(old_title)
      end

      # File should have reverted
      title = File.open(private_readme) { |file| file.gets('\n') }
      title.should eq(current_title)
    end

    it "should checkout a file and then restore it on error" do
      # Check the current file
      title = File.open(private_readme) { |file| file.gets('\n') }
      title.should eq(current_title)

      # Process a particular commit
      expect_raises(Exception, "something went wrong") do
        PlaceOS::Drivers::GitCommands.checkout("README.md", "0bcfa6e4a9ad832fadf799f15f269608d61086a7", private_drivers) do
          title = File.open(private_readme) { |file| file.gets('\n') }
          title.should eq(old_title)

          raise "something went wrong"
        end
      end

      # File should have reverted
      title = File.open(private_readme) { |file| file.gets('\n') }
      title.should eq(current_title)
    end
  end
end
