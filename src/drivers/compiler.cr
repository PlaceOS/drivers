require "./git_commands"

module PlaceOS::Drivers
  class Compiler
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

    def self.is_built?(source_file, commit = "HEAD", repository_drivers = @@drivers_dir)
      # Make sure we have an actual version hash of the file
      commit = self.normalize_commit(commit, source_file, repository_drivers)
      executable_path = File.join(@@bin_dir, self.executable_name(source_file, commit))
      File.exists?(executable_path) ? executable_path : nil
    end

    # repository is required to have a local `build.cr` file to support compilation
    def self.build_driver(source_file, commit = "HEAD", repository_drivers = @@drivers_dir, git_checkout = true, debug = false)
      # Ensure the bin directory exists
      Dir.mkdir_p @@bin_dir
      io = IO::Memory.new

      # Make sure we have an actual version hash of the file
      commit = normalize_commit(commit, source_file, repository_drivers)
      driver_executable = self.executable_name(source_file, commit)
      executable_path = ""
      result = 1

      GitCommands.file_lock(repository_drivers, source_file) do
        git_checkout = false if commit == "HEAD"

        # TODO: Expose some kind of status signalling
        # @@message = "compiling #{source_file} @ #{commit}"

        executable_path = File.join(@@bin_dir, driver_executable)
        build_script = File.join(repository_drivers, "src/build.cr")

        # If we are building head and don't want to check anything out
        # then we can assume we definitely want to re-build the driver
        begin
          File.delete(executable_path) if !git_checkout
        rescue
          # deleting a non-existant file will raise an exception
        end

        args = if debug
                 {repository_drivers, "crystal", "build", "--no-color", "--error-trace", "--debug", "-o", executable_path, build_script}
               else
                 {repository_drivers, "crystal", "build", "--no-color", "--error-trace", "-o", executable_path, build_script}
               end

        compile_proc = ->do
          result = Process.run(
            "./bin/exec_from",
            args,
            {
              "COMPILE_DRIVER" => source_file,
              "DEBUG"          => debug ? "1" : "0",
            },
            input: Process::Redirect::Close,
            output: io,
            error: io
          ).exit_code
        end

        # When developing you may not want to have to commit
        if git_checkout
          GitCommands.checkout(source_file, commit, repository_drivers) do
            compile_proc.call
          end
        else
          compile_proc.call
        end
      end

      {
        exit_status: result,
        output:      io.to_s,
        driver:      driver_executable,
        version:     commit,
        executable:  executable_path,
        repository:  repository_drivers,
      }
    end

    def self.compiled_drivers(source_file)
      # Get the executable name without commits to collect all versions
      exec_base = self.driver_slug(source_file)

      Dir.children(@@bin_dir).reject do |file|
        !file.starts_with?(exec_base) || file.includes?(".")
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
      GitCommands.repo_lock(repo_dir).write do
        # First check if the dependencies are satisfied
        result = Process.run(
          "./bin/exec_from",
          {repo_dir, "shards", "--no-color", "check"},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_code

        # Otherwise install shards
        if result != 0 || !io.to_s.includes?("Dependencies are satisfied")
          io.clear
          result = Process.run(
            "./bin/exec_from",
            {repo_dir, "shards", "--no-color", "install"},
            input: Process::Redirect::Close,
            output: io,
            error: io
          ).exit_code
        end
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
    def self.executable_name(driver_source : String, commit : String)
      "#{self.driver_slug(driver_source)}_#{commit}"
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
