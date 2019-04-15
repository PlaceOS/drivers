require "./spec_helper"

describe EngineDrivers::GitCommands do
  it "should list files in the repository" do
    files = EngineDrivers::GitCommands.ls
    (files.size > 0).should eq(true)
    files.includes?("shard.yml").should eq(true)
  end

  it "should list the revisions to a file in a repository" do
    changes = EngineDrivers::GitCommands.commits("shard.yml")
    (changes.size > 0).should eq(true)
    changes.map { |commit| commit[:subject] }.includes?("restructure application").should eq(true)
  end
end
