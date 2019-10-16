class ACAEngine::Drivers::Compiler
  @@drivers_dir = Dir.current
  @@repository_dir = File.expand_path("./repositories")
  @@bin_dir = "#{Dir.current}/bin/drivers"

  {% for name in [:drivers_dir, :repository_dir, :bin_dir] %}
    def self.{{name.id}}
      @@{{name.id}}
    end

    def self.{{name.id}}=(path)
      @@{{name.id}} = path
    end
  {% end %}

  def self.is_built?(source_file, commit = "head", repository = @@repository_dir)
    exec_name = self.executable_name(source_file)

    # Make sure we have an actual version hash of the file
    commit = self.normalize_commit(commit, source_file, repository)

    exe_output = File.join(@@bin_dir, "#{exec_name}_#{commit}")
    File.exists?(exe_output) ? exe_output : nil
  end

  # repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(source_file, commit = "head", repository = @@drivers_dir, git_checkout = true, debug = false)
    # Ensure the bin directory exists
    Dir.mkdir_p @@bin_dir
    io = IO::Memory.new

    exec_name = self.executable_name(source_file)
    exe_output = ""
    result = 1

    ACAEngine::Drivers::GitCommands.file_lock(repository, source_file) do
      # Make sure we have an actual version hash of the file
      commit = normalize_commit(commit, source_file, repository)
      git_checkout = false if commit == "head"

      # Want to expose some kind of status signalling
      # @@message = "compiling #{source_file} @ #{commit}"

      exe_output = File.join(@@bin_dir, "#{exec_name}_#{commit}")
      build_script = File.join(repository, "src/build.cr")

      # If we are building head and don't want to check anything out
      # then we can assume we definitely want to re-build the driver
      begin
        File.delete(exe_output) if !git_checkout
      rescue
        # deleting a non-existant file will raise an exception
      end

      args = if debug
               {repository, "crystal", "build", "--error-trace", "--debug", "-o", exe_output, build_script}
             else
               {repository, "crystal", "build", "--error-trace", "-o", exe_output, build_script}
             end

      compile_proc = ->do
        result = Process.run(
          "./bin/exec_from",
          args,
          {"COMPILE_DRIVER" => source_file},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_status
      end

      # When developing you may not want to have to
      if git_checkout
        ACAEngine::Drivers::GitCommands.checkout(source_file, commit) do
          compile_proc.call
        end
      else
        compile_proc.call
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
    exec_name = self.executable_name(source_file)
    exe_output = "#{exec_name}_"

    Dir.children(@@bin_dir).reject do |file|
      !file.starts_with?(exe_output) || file.includes?(".")
    end
  end

  def self.compiled_drivers
    Dir.children(@@bin_dir).reject { |file| file.includes?(".") || File.directory?(file) }
  end

  def self.repositories(working_dir = @@repository_dir)
    Dir.children(working_dir).reject { |file| File.file?(file) }
  end

  # Runs shards install to ensure driver builds will succeed
  def self.install_shards(repository, working_dir = @@repository_dir)
    io = IO::Memory.new
    result = 1

    repo_dir = File.expand_path(File.join(working_dir, repository))

    # NOTE:: supports recursive locking so can perform multiple repository
    # operations in a single lock. i.e. clone + shards install
    ACAEngine::Drivers::GitCommands.repo_lock(repo_dir).write do
      result = Process.run(
        "./bin/exec_from",
        {repo_dir, "shards", "--no-color", "install"},
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

  def self.clone_and_install(
    repository : String,
    repository_uri : String,
    username : String? = nil,
    password : String? = nil,
    working_dir : String = @@repository_dir,
    pull_if_exists : Bool = true
  )
    ACAEngine::Drivers::GitCommands.repo_lock(repository).write do
      clone_result = ACAEngine::Drivers::GitCommands.clone(repository, repository_uri, username, password, working_dir)
      raise "failed to clone\n#{clone_result[:output]}" unless clone_result[:exit_status] == 0

      # Pull if already cloned and pull intended
      if clone_result[:output].includes?("already exists") && pull_if_exists
        pull_result = ACAEngine::Drivers::GitCommands.pull(repository, working_dir)
        raise "failed to pull\n#{pull_result}" unless pull_result[:exit_status] == 0
      end

      install_result = install_shards(repository, working_dir)
      raise "failed to install shards\n#{install_result[:output]}" unless install_result[:exit_status] == 0
    end
  end

  # Generate executable name from driver file path
  # Removes ".cr" extension and normalises slashes and dots in path
  def self.executable_name(source_file) : String
    source_file.rchop(".cr").gsub(/\/|\./, "_")
  end

  def self.current_commit(source_file, repository)
    ACAEngine::Drivers::GitCommands.commits(source_file, 1, repository)[0][:commit]
  end

  # Ensure commit is an actual version hash of a file
  def self.normalize_commit(commit, source_file, repository) : String
    # Make sure we have an actual version hash of the file
    if commit == "head"
      if ACAEngine::Drivers::GitCommands.diff(source_file, repository).empty?
        # Allow uncommited files to be built
        begin
          commit = self.current_commit(source_file, repository)
        rescue
        end
      end
    end

    commit
  end
end
