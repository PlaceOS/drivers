class EngineDrivers::Compiler
  COMPILE_MUTEX = Mutex.new
  START_DIR     = Dir.current
  BIN_DIR       = "#{START_DIR}/bin/drivers"

  @@drivers_dir = Dir.current
  @@busy = false
  @@message = "idle"

  def self.set_drivers_dir(path)
    @@drivers_dir = path
  end

  # TODO:: if driver in external git repo
  # Make sure that we change the directory for process run
  # Repositories should shard update when they are cloned initially or updated

  # repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(source_file, commit = "head", repository = @@drivers_dir)
    Dir.mkdir_p BIN_DIR

    io = IO::Memory.new
    exec_name = source_file.gsub(/\/|\./, "_")
    exe_output = ""
    result = nil

    COMPILE_MUTEX.synchronize do
      begin
        @@busy = true

        # Might be located in a user definied repository
        Dir.cd(repository)

        # Make sure we have an actual version hash of the file
        if commit == "head"
          commit = EngineDrivers::GitCommands.commits(source_file, 1)[0][:commit]
        end
        @@message = "compiling #{source_file} @ #{commit}"

        exe_output = "#{BIN_DIR}/#{commit}_#{exec_name}"
        EngineDrivers::GitCommands.checkout(source_file, commit) do
          result = Process.run(
            "crystal",
            {"build", "-o", exe_output, "./src/build.cr"},
            {"COMPILE_DRIVER" => source_file},
            input: Process::Redirect::Close,
            output: io,
            error: io
          )
        end
      ensure
        @@busy = false
        @@message = "idle"
        Dir.cd(START_DIR)
      end
    end

    {
      exit_status: result.try &.exit_status,
      output:      io.to_s,
      driver:      exec_name,
      version:     commit,
      executable:  exe_output,
      repository:  repository,
    }
  end
end
