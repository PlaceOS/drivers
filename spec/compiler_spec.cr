require "./spec_helper"

describe EngineDrivers::Compiler do
  it "should compile a driver" do
    # Test the executable is created
    result = EngineDrivers::Compiler.build_driver("drivers/aca/spec_helper.cr")
    result[:exit_status].should eq(0)
    File.exists?(result[:executable]).should eq(true)

    # Check it functions as expected
    io = IO::Memory.new
    Process.run(result[:executable], {"-h"},
      input: Process::Redirect::Close,
      output: io,
      error: io
    )
    io.to_s.starts_with?("Usage:").should eq(true)
  end

  it "should list compiled versions" do
    files = EngineDrivers::Compiler.compiled_drivers("drivers/aca/spec_helper.cr")
    files.should eq(["drivers_aca_spec_helper_cr_b495a86"])
  end

  it "should clone and install a repository" do
    EngineDrivers::Compiler.clone_and_install("rwlock", "https://github.com/spider-gazelle/readers-writer")
    File.file?(File.expand_path("./repositories/rwlock/shard.yml")).should eq(true)
    File.directory?(File.expand_path("./repositories/rwlock/bin")).should eq(true)
  end

  it "should compile a private driver" do
    # Clone the private driver repo
    EngineDrivers::Compiler.clone_and_install("private_drivers", "https://github.com/aca-labs/private_drivers.git")
    File.file?(File.expand_path("./repositories/private_drivers/drivers/aca/private_helper.cr")).should eq(true)

    # Test the executable is created
    result = EngineDrivers::Compiler.build_driver("drivers/aca/private_helper.cr", repository: File.join(EngineDrivers::Compiler.repository_dir, "private_drivers"))
    result[:exit_status].should eq(0)
    File.exists?(result[:executable]).should eq(true)

    # Check it functions as expected
    io = IO::Memory.new
    Process.run(result[:executable], {"-h"},
      input: Process::Redirect::Close,
      output: io,
      error: io
    )
    io.to_s.starts_with?("Usage:").should eq(true)

    # Delete the file
    File.delete(result[:executable])
  end

  with_server do
    it "should compile a private driver using the build API" do
      result = curl("POST", "/build?repository=private_drivers&driver=drivers/aca/private_helper.cr")
      result.status_code.should eq(201)
    end
  end

  it "should compile a private spec" do
    # Test the executable is created
    result = EngineDrivers::Compiler.build_driver(
      "drivers/aca/private_helper_spec.cr",
      repository: File.join(EngineDrivers::Compiler.repository_dir, "private_drivers"),
      git_checkout: false
    )
    result[:exit_status].should eq(0)
    File.exists?(result[:executable]).should eq(true)

    # Ensure the driver we want to test exists
    driver_file = File.join(EngineDrivers::Compiler.bin_dir, "drivers_aca_private_helper_cr_4f6e0cd")
    File.exists?(driver_file).should eq(true)

    # Check it functions as expected SPEC_RUN_DRIVER
    io = IO::Memory.new
    exit_status = Process.run(result[:executable],
      env: {"SPEC_RUN_DRIVER" => driver_file},
      input: Process::Redirect::Close,
      output: io,
      error: io
    ).exit_status
    exit_status.should eq(0)

    # Delete the file
    File.delete(result[:executable])
  end
end
