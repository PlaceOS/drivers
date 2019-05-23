class EngineDrivers::Compiler
  BIN_DIR = "#{Dir.current}/bin/drivers"

  @@drivers_dir = Dir.current
  @@repository_dir = File.expand_path("../repositories")

  def self.drivers_dir=(path)
    @@drivers_dir = path
  end

  def self.drivers_dir
    @@drivers_dir
  end

  def self.repository_dir=(path)
    @@repository_dir = path
  end

  def self.repository_dir
    @@repository_dir
  end

  # repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(source_file, commit = "head", repository = @@drivers_dir)
    # Ensure the bin directory exists
    Dir.mkdir_p BIN_DIR

    io = IO::Memory.new
    exec_name = source_file.gsub(/\/|\./, "_")
    exe_output = ""
    result = 1

    EngineDrivers::GitCommands.file_lock(repository, source_file) do
      # Make sure we have an actual version hash of the file
      if commit == "head"
        commit = EngineDrivers::GitCommands.commits(source_file, 1, repository)[0][:commit]
      end

      # Want to expose some kind of status signalling
      # @@message = "compiling #{source_file} @ #{commit}"

      exe_output = "#{BIN_DIR}/#{exec_name}_#{commit}"
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

  def self.compiled_drivers(source_file)
    exec_name = source_file.gsub(/\/|\./, "_")
    exe_output = "#{exec_name}_"

    Dir.children(BIN_DIR).reject do |file|
      !file.starts_with?(exe_output) || file.includes?(".")
    end
  end

  def self.compiled_drivers
    Dir.children(BIN_DIR).reject { |file| file.includes?(".") || File.directory?(file) }
  end

  def self.repositories(working_dir = @@repository_dir)
    Dir.children(working_dir).reject { |file| File.file?(file) }
  end

  # Runs shards install to ensure driver builds will succeed
  def self.install_shards(repository, working_dir = @@repository_dir)
    io = IO::Memory.new
    result = 1

    # NOTE:: supports recursive locking so can perform multiple repository
    # operations in a single lock. i.e. clone + shards install
    EngineDrivers::GitCommands.repo_lock(repository).write do
      result = Process.run(
        "./bin/exec_from",
        {File.join(working_dir, repository), "shards", "--no-color", "install"},
        input: Process::Redirect::Close,
        output: io,
        error: io
      ).exit_status
    end

    {
      exit_status: result,
      output:      io.to_s,
    }
  end

  def self.clone_and_install(repository, repository_uri, username = nil, password = nil, working_dir = @@repository_dir)
    EngineDrivers::GitCommands.repo_lock(repository).write do
      result = EngineDrivers::GitCommands.clone(repository, repository_uri, username, password, working_dir)
      raise "failed to clone\n#{result[:output]}" unless result[:exit_status] == 0
      result = install_shards(repository, working_dir)
      raise "failed to install shards\n#{result[:output]}" unless result[:exit_status] == 0
    end
  end
end
