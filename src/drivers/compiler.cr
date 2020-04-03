require "exec_from"

require "./git_commands"

module PlaceOS::Drivers
  class Compiler
    class_property drivers_dir : String = Dir.current
    class_property repository_dir : String = File.expand_path("./repositories")
    class_property bin_dir : String = "#{Dir.current}/bin/drivers"

    def self.is_built?(
      source_file : String,
      commit : String = "HEAD",
      repository_drivers : String = @@drivers_dir,
      binary_directory : String = @@bin_dir,
      id : String? = nil
    )
      # Make sure we have an actual version hash of the file
      commit = self.normalize_commit(commit, source_file, repository_drivers)
      executable_path = File.join(binary_directory, self.executable_name(source_file, commit, id))

      executable_path if File.exists?(executable_path)
    end

    # Repository is required to have a local `build.cr` file to support compilation
    def self.build_driver(
      source_file : String,
      commit : String = "HEAD",
      repository_drivers : String = @@drivers_dir,
      binary_directory : String = @@bin_dir,
      id : String? = nil,
      git_checkout : Bool = true,
      debug : Bool = false
    )
      # Ensure the bin directory exists
      Dir.mkdir_p binary_directory

      # Make sure we have an actual version hash of the file
      commit = normalize_commit(commit, source_file, repository_drivers)
      driver_executable = executable_name(source_file, commit, id)
      executable_path = nil

      result = GitCommands.file_lock(repository_drivers, source_file) do
        git_checkout = false if commit == "HEAD"

        # TODO: Expose some kind of status signalling compilation
        # @@message = "compiling #{source_file} @ #{commit}"

        executable_path = File.join(binary_directory, driver_executable)
        build_script = File.join(repository_drivers, "src/build.cr")

        # If we are building head and don't want to check anything out
        # then we can assume we definitely want to re-build the driver
        begin
          File.delete(executable_path) if !git_checkout && File.exists?(executable_path)
        rescue
          # Deleting a non-existant file will raise an exception
        end

        # When developing you may not want to have to commit
        if git_checkout
          GitCommands.checkout(source_file, commit, repository_drivers) do
            _compile(repository_drivers, executable_path, build_script, source_file, debug)
          end
        else
          _compile(repository_drivers, executable_path, build_script, source_file, debug)
        end
      end

      {
        exit_status: result[:exit_code],
        output:      result[:output].to_s,
        driver:      driver_executable,
        version:     commit,
        executable:  executable_path || "",
        repository:  repository_drivers,
      }
    end

    def self._compile(
      repository_drivers : String,
      executable_path : String,
      build_script : String,
      source_file : String,
      debug : Bool
    )
      arguments = ["build", "--no-color", "--error-trace", "-o", executable_path, build_script]
      arguments.insert(1, "--debug") if debug

      ExecFrom.exec_from(
        directory: repository_drivers,
        command: "crystal",
        arguments: arguments,
        environment: {
          "COMPILE_DRIVER" => source_file,
          "DEBUG"          => debug ? "1" : "0",
        })
    end

    # TODO: Accept an optional binary_directory rather than using @@bin_dir
    def self.compiled_drivers(source_file : String? = nil, id : String? = nil)
      if source_file.nil?
        Dir.children(@@bin_dir).reject do |file|
          file.includes?(".") || File.directory?(file)
        end
      else
        # Get the executable name without commits to collect all versions
        exec_base = self.driver_slug(source_file)
        Dir.children(@@bin_dir).select do |file|
          correct_base = file.starts_with?(exec_base) && !file.includes?(".")
          # Select for IDs
          id.nil? ? correct_base : (correct_base && file.ends_with?(id))
        end
      end
    end

    def self.repositories(working_dir : String = @@repository_dir)
      Dir.children(working_dir).reject { |file| File.file?(file) }
    end

    # Runs shards install to ensure driver builds will succeed
    def self.install_shards(repository, working_dir = @@repository_dir)
      repo_dir = File.expand_path(File.join(working_dir, repository))
      # NOTE:: supports recursive locking so can perform multiple repository
      # operations in a single lock. i.e. clone + shards install
      GitCommands.repo_lock(repo_dir).write do
        # First check if the dependencies are satisfied
        result = ExecFrom.exec_from(repo_dir, "shards", {"--no-color", "check"})
        check_output = result[:output].to_s
        check_exit_code = result[:exit_code]

        if check_exit_code == 0 || check_output.includes?("Dependencies are satisfied")
          {
            exit_status: check_exit_code,
            output:      check_output,
          }
        else
          # Otherwise install shards
          result = ExecFrom.exec_from(repo_dir, "shards", {"--no-color", "install"})
          {
            exit_status: result[:exit_code],
            output:      result[:output].to_s,
          }
        end
      end
    end

    def self.clone_and_install(
      repository : String,
      repository_uri : String,
      username : String? = nil,
      password : String? = nil,
      working_dir : String = @@repository_dir,
      pull_if_exists : Bool = true
    )
      GitCommands.repo_lock(repository).write do
        clone_result = GitCommands.clone(repository, repository_uri, username, password, working_dir)
        raise "failed to clone\n#{clone_result[:output]}" unless clone_result[:exit_status] == 0

        # Pull if already cloned and pull intended
        if clone_result[:output].includes?("already exists") && pull_if_exists
          pull_result = GitCommands.pull(repository, working_dir)
          raise "failed to pull\n#{pull_result}" unless pull_result[:exit_status] == 0
        end

        install_result = install_shards(repository, working_dir)
        raise "failed to install shards\n#{install_result[:output]}" unless install_result[:exit_status] == 0
      end
    end

    # Removes ".cr" extension and normalises slashes and dots in path
    def self.driver_slug(path : String) : String
      path.rchop(".cr").gsub(/\/|\./, "_")
    end

    # Generate executable name from driver file path and commit
    # Optionally provide an id.
    def self.executable_name(driver_source : String, commit : String, id : String?)
      if id.nil?
        "#{self.driver_slug(driver_source)}_#{commit}"
      else
        "#{self.driver_slug(driver_source)}_#{commit}_#{id}"
      end
    end

    def self.current_commit(source_file, repository)
      GitCommands.commits(source_file, 1, repository)[0][:commit]
    end

    # Ensure commit is an actual version hash of a file
    def self.normalize_commit(commit, source_file, repository) : String
      # Make sure we have an actual version hash of the file
      if commit == "HEAD"
        if GitCommands.diff(source_file, repository).empty?
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
end
