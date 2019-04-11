# TODO:: create a shard that compiles on install (like ameba)
# should accept a DIR and a command as a param, it switches dir and executes

class EngineDrivers::Compiler
  BIN_DIR = "#{Dir.current}/bin/drivers"

  @@drivers_dir = Dir.current
  @@busy = false
  @@message = "idle"

  def self.drivers_dir=(path)
    @@drivers_dir = path
  end

  def self.drivers_dir
    @@drivers_dir
  end

  # TODO:: if driver in external git repo
  # Make sure that we change the directory for process run
  # Repositories should shard update when they are cloned initially or updated

  # repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(source_file, commit = "head", repository = @@drivers_dir)
    # Ensure the bin directory exists
    Dir.mkdir_p BIN_DIR

    io = IO::Memory.new
    exec_name = source_file.gsub(/\/|\./, "_")
    exe_output = ""
    result = 1

    get_lock(repository).synchronize do
      begin
        @@busy = true

        # Make sure we have an actual version hash of the file
        if commit == "head"
          commit = EngineDrivers::GitCommands.commits(source_file, 1, repository)[0][:commit]
        end
        @@message = "compiling #{source_file} @ #{commit}"

        exe_output = "#{BIN_DIR}/#{commit}_#{exec_name}"
        EngineDrivers::GitCommands.checkout(source_file, commit) do
          result = Process.run(
            "./bin/exec_from",
            {repository, "crystal", "build", "-o", exe_output, "./src/build.cr"},
            {"COMPILE_DRIVER" => source_file},
            input: Process::Redirect::Close,
            output: io,
            error: io
          ).exit_status
        end
      ensure
        @@busy = false
        @@message = "idle"
      end
    end

    {
      exit_status: result,
      output:      io.to_s,
      driver:      exec_name,
      version:     commit,
      executable:  exe_output,
      repository:  repository,
    }
  end

  # Runs shards install to ensure driver builds will succeed
  def self.install_shards(repository = @@drivers_dir)
    io = IO::Memory.new
    result = 1

    # NOTE:: supports recursive locking so can perform multiple repository
    # operations in a single lock. i.e. clone + shards install
    get_lock(repository).synchronize do
      begin
        @@busy = true
        @@message = "installing shards"

        result = Process.run(
          "./bin/exec_from",
          {repository, "shards", "--no-color", "install"},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_status
      ensure
        @@busy = false
        @@message = "idle"
      end
    end

    {
      exit_status: result,
      output:      io.to_s,
    }
  end

  def self.clone(repository_uri, folder_name, username = nil, password = nil)
    io = IO::Memory.new
    result = 1
  end

  # Proxy the get lock requests to git commands
  def self.get_lock(*args)
    EngineDrivers::GitCommands.get_lock(*args)
  end
end
