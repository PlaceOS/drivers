require "./spec_helper"

module PlaceOS::Drivers
  describe Compiler do
    it "should compile a driver" do
      # Test the executable is created
      result = PlaceOS::Drivers::Compiler.build_driver("drivers/place/spec_helper.cr")
      result[:exit_status].should eq(0)
      File.exists?(result[:executable]).should be_true

      # Check it functions as expected
      io = IO::Memory.new
      Process.run(result[:executable], {"-h"},
        input: Process::Redirect::Close,
        output: io,
        error: io
      )
      io.to_s.starts_with?("Usage:").should be_true
    end

    it "should list compiled versions" do
      files = PlaceOS::Drivers::Compiler.compiled_drivers("drivers/place/spec_helper.cr")

      files.size.should eq(1)
      files.first.should start_with("drivers_place_spec_helper_")
    end

    it "should clone and install a repository" do
      PlaceOS::Drivers::Compiler.clone_and_install("rwlock", "https://github.com/spider-gazelle/readers-writer")
      File.file?(File.expand_path("./repositories/rwlock/shard.yml")).should be_true
      File.directory?(File.expand_path("./repositories/rwlock/bin")).should be_true
    end

    it "should compile a private driver" do
      # Clone the private driver repo
      PlaceOS::Drivers::Compiler.clone_and_install("private_drivers", "https://github.com/placeos/private-drivers.git")
      File.file?(File.expand_path("./repositories/private_drivers/drivers/place/private_helper.cr")).should be_true

      # Test the executable is created
      result = PlaceOS::Drivers::Compiler.build_driver(
        "drivers/place/private_helper.cr",
        repository_drivers: File.join(PlaceOS::Drivers::Compiler.repository_dir, "private_drivers")
      )

      result[:exit_status].should eq(0)
      File.exists?(result[:executable]).should be_true

      # Check it functions as expected
      io = IO::Memory.new
      Process.run(result[:executable], {"-h"},
        input: Process::Redirect::Close,
        output: io,
        error: io
      )
      io.to_s.starts_with?("Usage:").should be_true

      # Delete the file
      File.delete(result[:executable])
    end

    with_server do
      it "should compile a private driver using the build API" do
        result = curl("POST", "/build?repository=private_drivers&driver=drivers/place/private_helper.cr")
        result.status_code.should eq(201)
      end
    end

    it "should compile a private spec" do
      # Clone the private driver repo
      PlaceOS::Drivers::Compiler.clone_and_install("private_drivers", "https://github.com/placeos/private-drivers.git")
      repository_path = Helper.get_repository_path("private_drivers")
      # Test the executable is created
      result = PlaceOS::Drivers::Compiler.build_driver(
        "drivers/place/private_helper_spec.cr",
        repository_drivers: repository_path,
        git_checkout: false
      )

      spec_executable = result[:executable]
      result[:exit_status].should eq(0)
      File.exists?(spec_executable).should be_true

      result = PlaceOS::Drivers::Compiler.build_driver(
        "drivers/place/private_helper.cr",
        repository_drivers: repository_path,
        git_checkout: false
      )

      # Ensure the driver we want to test exists
      executable = result[:executable]
      File.exists?(executable).should be_true

      # Check it functions as expected SPEC_RUN_DRIVER
      io = IO::Memory.new
      exit_status = Process.run(spec_executable,
        env: {"SPEC_RUN_DRIVER" => executable},
        input: Process::Redirect::Close,
        output: io,
        error: io
      ).exit_code
      exit_status.should eq(0)

      # Delete the file
      File.delete(executable)
      File.delete(executable + ".dwarf")
      File.delete(spec_executable)
      File.delete(spec_executable + ".dwarf")
    end
  end
end
