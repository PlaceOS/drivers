require "./spec_helper"
require "yaml"

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

  it "should checkout a particular revision of a file and then restore it" do
    # Check the current file
    yaml = File.open("shard.yml") { |file| YAML.parse(file) }
    name = yaml["name"].to_s
    (name == "engine-drivers").should eq(true)

    # Process a particular commit
    EngineDrivers::GitCommands.checkout("shard.yml", "18f149d") do
      yaml = File.open("shard.yml") { |file| YAML.parse(file) }
      (yaml["name"].to_s == "app").should eq(true)
    end

    # File should have reverted
    yaml = File.open("shard.yml") { |file| YAML.parse(file) }
    (yaml["name"].to_s).should eq(name)
  end

  it "should checkout a file and then restore it on error" do
    # Check the current file
    yaml = File.open("shard.yml") { |file| YAML.parse(file) }
    name = yaml["name"].to_s
    (name == "engine-drivers").should eq(true)

    # Process a particular commit
    expect_raises(Exception, "something went wrong") do
      EngineDrivers::GitCommands.checkout("shard.yml", "18f149d") do
        yaml = File.open("shard.yml") { |file| YAML.parse(file) }
        (yaml["name"].to_s == "app").should eq(true)

        raise "something went wrong"
      end
    end

    # File should have reverted
    yaml = File.open("shard.yml") { |file| YAML.parse(file) }
    (yaml["name"].to_s).should eq(name)
  end
end
