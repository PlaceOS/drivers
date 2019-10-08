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
    exec_name = source_file.gsub(/\/|\./, "_")

    # Make sure we have an actual version hash of the file
    if commit == "head"
      diff = ACAEngine::Drivers::GitCommands.diff(source_file, repository)

      if diff.empty?
        # Allow uncommited files to be built
        begin
          commit = ACAEngine::Drivers::GitCommands.commits(source_file, 1, repository)[0][:commit]
        rescue
        end
      end
    end

    exe_output = File.join(@@bin_dir, "#{exec_name}_#{commit}")
    File.exists?(exe_output) ? exe_output : nil
  end

  # repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(source_file, commit = "head", repository = @@drivers_dir, git_checkout = true, debug = false)
    # Ensure the bin directory exists
    Dir.mkdir_p @@bin_dir
    io = IO::Memory.new

    exec_name = source_file.gsub(/\/|\./, "_")
    exe_output = ""
    result = 1

    ACAEngine::Drivers::GitCommands.file_lock(repository, source_file) do
      # Make sure we have an actual version hash of the file
      if commit == "head"
        diff = ACAEngine::Drivers::GitCommands.diff(source_file, repository)
        if diff.empty?
          # Allow uncommited files to be built
          begin
            commit = ACAEngine::Drivers::GitCommands.commits(source_file, 1, repository)[0][:commit]
          rescue
            git_checkout = false
          end
        else
          git_checkout = false
        end
      end

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
    exec_name = source_file.gsub(/\/|\./, "_")
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

  def self.clone_and_install(repository, repository_uri, username = nil, password = nil, working_dir = @@repository_dir)
    ACAEngine::Drivers::GitCommands.repo_lock(repository).write do
      result = ACAEngine::Drivers::GitCommands.clone(repository, repository_uri, username, password, working_dir)
      raise "failed to clone\n#{result[:output]}" unless result[:exit_status] == 0
      result = install_shards(repository, working_dir)
      raise "failed to install shards\n#{result[:output]}" unless result[:exit_status] == 0
    end
  end
end
