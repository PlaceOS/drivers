require "./command_failure"
require "./git_commands"
require "./compiler"

module ACAEngine::Drivers::Helper
  extend self

  # Returns a list of repository paths
  def repositories : Array(String)
    ACAEngine::Drivers::Compiler.repositories
  end

  # Returns a list of driver source file paths in a repository
  # defaults to ACA repository, i.e. this one
  def drivers(repository : String? = nil) : Array(String)
    result = [] of String
    Dir.cd(get_repository_path(repository)) do
      Dir.glob("drivers/**/*.cr") do |file|
        result << file unless file.ends_with?("_spec.cr")
      end
    end
    result
  end

  # Returns a list of compiled driver file paths
  # (across all repositories)
  def compiled_drivers : Array(String)
    ACAEngine::Drivers::Compiler.compiled_drivers
  end

  # Check if a version of a driver exists
  def compiled?(driver : String, commit : String) : Bool
    File.exists?(driver_path(driver, commit))
  end

  # Generates path to a driver
  def driver_path(driver, commit)
    exec_name = driver.gsub(/\/|\./, "_")
    file_name = "#{exec_name}_#{commit}"
    File.join(ACAEngine::Drivers::Compiler.bin_dir, file_name)
  end

  # Repository commits
  #
  # [{commit:, date:, author:, subject:}, ...]
  def repository_commits(repository : String? = nil, count = 50)
    ACAEngine::Drivers::GitCommands.repository_commits(get_repository_path(repository), count)
  end

  # File level commits
  # [{commit:, date:, author:, subject:}, ...]
  def commits(driver : String, repository : String? = nil, count = 50)
    ACAEngine::Drivers::GitCommands.commits(driver, count, get_repository_path(repository))
  end

  # Returns the latest commit hash for a repository
  def repository_commit_hash(repository : String? = nil)
    ACAEngine::Drivers::GitCommands.repository_commits(get_repository_path(repository), 1)[0][:commit]
  end

  # Takes a file path with a repository path and compiles it
  # [{exit_status:, output:, driver:, version:, executable:, repository:}, ...]
  def compile_driver(driver : String, repository : String? = nil, commit = "head")
    ACAEngine::Drivers::Compiler.build_driver(driver, commit, get_repository_path(repository))
  end

  # Deletes a compiled driver
  # not providing a commit deletes all versions of the driver
  def delete_driver(driver : String, repository : String? = nil, commit = nil) : Array(String)
    # Check repository to prevent abuse (don't want to delete the wrong thing)
    repository = get_repository_path(repository)
    ACAEngine::Drivers::GitCommands.checkout(driver, commit || "head", repository) do
      return [] of String unless File.exists?(File.join(repository, driver))
    end

    files = if commit
              exec_name = driver.gsub(/\/|\./, "_")
              ["#{exec_name}_#{commit}"]
            else
              ACAEngine::Drivers::Compiler.compiled_drivers(driver)
            end

    files.each do |file|
      File.delete File.join(ACAEngine::Drivers::Compiler.bin_dir, file)
    end
    files
  end

  private def get_repository_path(repository : String?) : String
    if repository
      repo = File.expand_path(File.join(ACAEngine::Drivers::Compiler.repository_dir, repository))
      valid = repo.starts_with?(ACAEngine::Drivers::Compiler.repository_dir) && repo != "/" && repository.size > 0 && !repository.includes?("/") && !repository.includes?(".")
      raise "invalid repository: #{repository}" unless valid
      repo
    else
      ACAEngine::Drivers::Compiler.drivers_dir
    end
  end
end
