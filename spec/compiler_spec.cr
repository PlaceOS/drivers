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
end
