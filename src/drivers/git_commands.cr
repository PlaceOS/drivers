require "exec_from"
require "rwlock"
require "uri"

require "./command_failure"
require "./compiler"

module PlaceOS::Drivers
  class GitCommands
    # Will really only be an issue once threads come along
    @@lock_manager = Mutex.new

    # Allow multiple file level operations to occur in parrallel
    # File level operations are readers, repo level are writers
    @@repository_lock = {} of String => RWLock

    # Ensure only a single git operation is occuring at once to avoid corruption
    @@operation_lock = {} of String => Mutex

    # Ensures only a single operation on an individual file occurs at once
    # This enables multi-version compilation to occur without clashing
    @@file_lock = {} of String => Hash(String, Mutex)

    def self.ls(repository = Compiler.drivers_dir)
      result = basic_operation(repository) do
        ExecFrom.exec_from(repository, "git", {"--no-pager", "ls-files"})
      end

      output = result[:output].to_s
      exit_code = result[:exit_code]
      raise CommandFailure.new(exit_code, "git ls-files failed with #{exit_code} in path #{repository}: #{output}") if exit_code != 0

      output.split("\n")
    end

    alias Commit = NamedTuple(commit: String, date: String, author: String, subject: String)

    def self.commits(file_name, count = 50, repository = Compiler.drivers_dir) : Array(Commit)
      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      result = file_operation(repository, file_name) do
        ExecFrom.exec_from(repository, "git", {"--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s, file_name})
      end

      output = result[:output].to_s
      exit_code = result[:exit_code]
      raise CommandFailure.new(exit_code, "git log failed with #{exit_code} in path #{repository}: #{output}") if exit_code != 0

      output.strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map(&.strip.split("\n").map &.strip)
        .map do |commit|
          {
            commit:  commit[0],
            date:    commit[1],
            author:  commit[2],
            subject: commit[3],
          }
        end
    end

    def self.diff(file_name, repository = Compiler.drivers_dir)
      result = file_operation(repository, file_name) do
        ExecFrom.exec_from(repository, "git", {"--no-pager", "diff", "--no-color", file_name})
      end

      output = result[:output].to_s
      exit_code = result[:exit_code]

      # File most likely doesn't exist
      return "error: #{output}" if exit_code != 0

      output.strip
    end

    def self.repository_commits(repository = Compiler.drivers_dir, count = 50)
      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      result = repo_lock(repository).write do
        ExecFrom.exec_from(repository, "git", {"--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s})
      end

      output = result[:output].to_s
      exit_code = result[:exit_code]
      raise CommandFailure.new(exit_code, "git log failed with #{exit_code} in path #{repository}: #{output}") if exit_code != 0

      output.strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map(&.strip.split("\n").map &.strip)
        .map do |commit|
          {
            commit:  commit[0],
            date:    commit[1],
            author:  commit[2],
            subject: commit[3],
          }
        end
    end

    def self.checkout(file : String, commit : String = "HEAD", repository : String = Compiler.drivers_dir)
      # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
      file_lock(repository, file) do
        begin
          _checkout(repository, file, commit)
          yield file
        ensure
          # reset the file back to head
          _checkout(repository, file, "HEAD")
        end
      end
    end

    # Checkout a file relative to a directory
    protected def self._checkout(repository_directory : String, file : String, commit : String)
      result = operation_lock(repository_directory).synchronize do
        ExecFrom.exec_from(repository_directory, "git", {"checkout", commit, "--", file})
      end

      exit_code = result[:exit_code]
      raise CommandFailure.new(exit_code, "git checkout failed with #{exit_code} in path #{repository_directory}: #{result[:output].to_s}") if exit_code != 0
    end

    def self.pull(repository, working_dir = Compiler.repository_dir)
      working_dir = File.expand_path(working_dir)
      repo_dir = File.expand_path(repository, working_dir)

      # Double check the input directories
      unless repo_dir.starts_with?(working_dir)
        raise "invalid folder structure. Working directory: '#{working_dir}', repository: '#{repository}', resulting path: '#{repo_dir}'"
      end

      raise "repository does not exist. Path: '#{repo_dir}'" unless File.directory?(repo_dir)

      # Assumes no password required. Re-clone if this has changed.
      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      result = repo_operation(repo_dir) do
        ExecFrom.exec_from(repo_dir, "git", {"pull"}, environment: {"GIT_TERMINAL_PROMPT" => "0"})
      end

      {
        exit_status: result[:exit_code],
        output:      result[:output].to_s,
      }
    end

    def self.clone(repository, repository_uri, username = nil, password = nil, working_dir = Compiler.repository_dir)
      working_dir = File.expand_path(working_dir)
      repo_dir = File.expand_path(File.join(working_dir, repository))

      # Ensure we are rm -rf a sane folder - don't want to delete root for example
      valid = repo_dir.starts_with?(working_dir) && repo_dir != "/" && repository.size > 0 && !repository.includes?("/") && !repository.includes?(".")
      raise "invalid folder structure. Working directory: '#{working_dir}', repository: '#{repository}', resulting path: '#{repo_dir}'" unless valid

      if username && password
        uri_builder = URI.parse(repository_uri)
        uri_builder.user = username
        uri_builder.password = password
        repository_uri = uri_builder.to_s
      end

      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      repo_lock(repo_dir).write do
        # Ensure the repository directory exists (it should)
        Dir.mkdir_p working_dir
        repository_path = File.join(working_dir, repository)

        # Check if there's an existing repo
        if Dir.exists?(File.join(repository_path, ".git"))
          {
            exit_status: 0,
            output:      "already exists",
          }
        else
          # Ensure the cloned into directory does not exist
          ExecFrom.exec_from(working_dir, "rm", {"-rf", repository}) if Dir.exists?(repository_path)

          # Clone the repository
          result = ExecFrom.exec_from(working_dir, "git", {"clone", repository_uri, repository}, environment: {"GIT_TERMINAL_PROMPT" => "0"})

          {
            exit_status: result[:exit_code],
            output:      result[:output].to_s,
          }
        end
      end
    end

    # https://stackoverflow.com/questions/6245570/how-to-get-the-current-branch-name-in-git
    def self.current_branch(repository)
      io = IO::Memory.new
      exit_status = basic_operation(repository) do
        Process.run(
          "./bin/exec_from", {repository, "git", "rev-parse", "--abbrev-ref", "HEAD"},
          input: Process::Redirect::Close,
          output: io,
          error: io,
        ).exit_code
      end
      raise CommandFailure.new(exit_status, "git rev-parse failed with #{exit_status} in path #{repository}: #{io.to_s}") if exit_status != 0
      io.to_s.strip
    end

    # Use this for simple git operations, such as `git ls`
    def self.basic_operation(repository)
      repo_lock(repository).read do
        operation_lock(repository).synchronize { yield }
      end
    end

    # Use this for simple file operations, such as file commits
    def self.file_operation(repository, file)
      # This is the order of locking that should occur when performing an operation
      # * Read access to repository (not a global change or exclusive access)
      # * File lock ensures exclusive access to this file
      # * Operation lock ensures only a single git command is executing at a time
      #
      # The `checkout` function is an example of performing an operation on a file
      # that requires multiple git operations
      repo_lock(repository).read do
        file_lock(repository, file).synchronize do
          operation_lock(repository).synchronize { yield }
        end
      end
    end

    # Anything that expects a clean repository
    def self.repo_operation(repository)
      repo_lock(repository).write do
        operation_lock(repository).synchronize do
          # Reset incase of a crash during a file operation
          result = ExecFrom.exec_from(repository, "git", {"reset", "--hard"})

          exit_code = result[:exit_code]
          raise CommandFailure.new(exit_code, "git reset --hard failed with #{exit_code} in path #{repository}: #{result[:output].to_s}") if exit_code != 0
          yield
        end
      end
    end

    def self.file_lock(repository, file)
      repo_lock(repository).read do
        file_lock(repository, file).synchronize do
          yield
        end
      end
    end

    def self.file_lock(repository, file) : Mutex
      @@lock_manager.synchronize do
        locks = @@file_lock[repository]?
        @@file_lock[repository] = locks = Hash(String, Mutex).new unless locks

        if lock = locks[file]?
          lock
        else
          locks[file] = Mutex.new(:reentrant)
        end
      end
    end

    def self.repo_lock(repository) : RWLock
      @@lock_manager.synchronize do
        if lock = @@repository_lock[repository]?
          lock
        else
          @@repository_lock[repository] = RWLock.new
        end
      end
    end

    def self.operation_lock(repository) : Mutex
      @@lock_manager.synchronize do
        if lock = @@operation_lock[repository]?
          lock
        else
          @@operation_lock[repository] = Mutex.new
        end
      end
    end
  end
end
