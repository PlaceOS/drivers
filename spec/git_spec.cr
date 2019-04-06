require "./spec_helper"

describe EngineDrivers::GitCommands do
  it "should list files in the repository" do
    files = EngineDrivers::GitCommands.ls
    (files.size > 0).should eq(true)
    files.includes?("shard.yml").should eq(true)
  end
end
