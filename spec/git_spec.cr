require "./spec_helper"

describe GitCommands do
  it "should list files in the repository" do
    files = GitCommands.ls
    (files.size > 0).should eq(true)
    files.includes?("shard.yml").should eq(true)
  end
end
