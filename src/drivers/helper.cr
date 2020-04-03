require "./command_failure"
require "./compiler"
require "./git_commands"

module PlaceOS::Drivers
  module Helper
    extend self

    # Returns a list of repository paths
    def repositories : Array(String)
      Compiler.repositories
    end

    # Returns a list of driver source file paths in a repository
    # defaults to PlaceOS repository, i.e. this one
    def drivers(repository_directory : String? = nil) : Array(String)
      Dir.cd(get_repository_path(repository_directory)) do
        Dir.glob("drivers/**/*.cr").select do |file|
          !file.ends_with?("_spec.cr")
        end
      end
    end

    # Returns a list of compiled driver file paths
    # (across all repositories)
    def compiled_drivers(id : String? = nil) : Array(String)
      Compiler.compiled_drivers(id)
    end

    # Check if a version of a driver exists
    def compiled?(driver_file : String, commit : String, id : String? = nil) : Bool
      File.exists?(driver_binary_path(driver_file, commit, id))
    end

    # Generates path to a driver executable
    def driver_binary_path(driver_file : String, commit : String, id : String? = nil)
      File.join(Compiler.bin_dir, driver_binary_name(driver_file, commit, id))
    end

    # Generates the name of a driver binary
    def driver_binary_name(driver_file : String, commit : String, id : String? = nil)
      Compiler.executable_name(driver_file, commit, id)
    end

    # Repository commits
    #
    # [{commit:, date:, author:, subject:}, ...]
    def repository_commits(repository_directory : String? = nil, count = 50)
      GitCommands.repository_commits(get_repository_path(repository_directory), count)
    end

    # Returns the latest commit hash for a repository
    def repository_commit_hash(repository_directory : String? = nil)
      repository_commits(repository_directory, 1).first[:commit]
    end

    # File level commits
    # [{commit:, date:, author:, subject:}, ...]
    def commits(file_path : String, repository_directory : String? = nil, count = 50)
      GitCommands.commits(file_path, count, get_repository_path(repository_directory))
    end

    # Returns the latest commit hash for a file
    def file_commit_hash(file_path : String, repository_directory : String? = nil)
      commits(file_path, repository_directory, 1).first[:commit]
    end

    # Takes a file path with a repository path and compiles it
    # [{exit_status:, output:, driver:, version:, executable:, repository:}, ...]
    def compile_driver(
      driver_file : String,
      repository_directory : String? = nil,
      commit : String = "HEAD",
      id : String? = nil
    )
      repository_path = get_repository_path(repository_directory)
      Compiler.build_driver(driver_file, commit, repository_path, id: id)
    end

    # Deletes a compiled driver
    # not providing a commit deletes all versions of the driver
    def delete_driver(
      driver_file : String,
      repository_directory : String? = nil,
      commit : String? = nil,
      id : String? = nil
    ) : Array(String)
      # Check repository to prevent abuse (don't want to delete the wrong thing)
      repository_path = get_repository_path(repository_directory)
      GitCommands.checkout(driver, commit || "HEAD", repository_path) do
        return [] of String unless File.exists?(File.join(repository_path, driver_file))
      end

      files = if commit
                [driver_binary_name(driver_file, commit, id)]
              else
                compiled_drivers(id)
              end

      files.each do |file|
        File.delete(File.join(Compiler.bin_dir, file))
      end

      files
    end

    def get_repository_path(repository_directory : String?) : String
      if repository_directory
        repo = File.expand_path(File.join(Compiler.repository_dir, repository_directory))
        valid = repo.starts_with?(Compiler.repository_dir) && repo != "/" && repository_directory.size > 0 && !repository_directory.includes?("/") && !repository_directory.includes?(".")
        raise "Invalid repository directory: #{repository_directory}" unless valid
        repo
      else
        Compiler.drivers_dir
      end
    end
  end
end
