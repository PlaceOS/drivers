require "rwlock"
require "uri"

require "./command_failure"
require "./compiler"

module ACAEngine::Drivers
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
      io = IO::Memory.new
      result = basic_operation(repository) do
        Process.run(
          "./bin/exec_from", {repository, "git", "--no-pager", "ls-files"},
          input: Process::Redirect::Close,
          output: io,
          error: Process::Redirect::Close
        )
      end

      exit_status = result.exit_status % 256
      raise CommandFailure.new(exit_status, "git ls-files failed with #{exit_status} in path #{repository}") if exit_status != 0

      io.to_s.split("\n")
    end

    alias Commit = NamedTuple(commit: String, date: String, author: String, subject: String)

    def self.commits(file_name, count = 50, repository = Compiler.drivers_dir) : Array(Commit)
      io = IO::Memory.new

      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      result = file_operation(repository, file_name) do
        Process.run(
          "./bin/exec_from", {repository, "git", "--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s, file_name},
          input: Process::Redirect::Close,
          output: io,
          error: Process::Redirect::Close
        )
      end

      exit_status = result.exit_status % 256
      raise CommandFailure.new(result.exit_status, "git log failed with #{exit_status} in path #{repository}") if exit_status != 0

      io.to_s.strip.split("<--\n\n-->")
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
      io = IO::Memory.new

      result = file_operation(repository, file_name) do
        Process.run(
          "./bin/exec_from", {repository, "git", "--no-pager", "diff", "--no-color", file_name},
          input: Process::Redirect::Close,
          output: io,
          error: Process::Redirect::Close
        )
      end

      # File most likely doesn't exist
      return "error" if (result.exit_status % 256) != 0
      io.to_s.strip
    end

    def self.repository_commits(repository = Compiler.drivers_dir, count = 50)
      io = IO::Memory.new

      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      result = repo_lock(repository).write do
        Process.run(
          "./bin/exec_from", {repository, "git", "--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s},
          input: Process::Redirect::Close,
          output: io,
          error: Process::Redirect::Close
        )
      end

      exit_status = result.exit_status % 256
      raise CommandFailure.new(exit_status, "git log failed with #{exit_status} in path #{repository}") if exit_status != 0

      io.to_s.strip.split("<--\n\n-->")
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

    def self.checkout(file, commit = "head", repository = Compiler.drivers_dir)
      # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
      op_lock = operation_lock(repository)

      file_lock(repository, file) do
        begin
          result = op_lock.synchronize do
            Process.run(
              "./bin/exec_from",
              {repository, "git", "checkout", commit, "--", file}
            )
          end

          exit_status = result.exit_status % 256
          raise CommandFailure.new(exit_status, "git checkout failed with #{exit_status} in path #{repository}") if exit_status != 0

          yield file
        ensure
          # reset the file back to head
          op_lock.synchronize do
            Process.run(
              "./bin/exec_from",
              {repository, "git", "checkout", "HEAD", "--", file}
            )
          end
        end
      end
    end

    def self.pull(repository, working_dir = Compiler.repository_dir)
      working_dir = File.expand_path(working_dir)
      repo_dir = File.expand_path(repository, working_dir)

      # Double check the inputs
      unless repo_dir.starts_with?(working_dir)
        raise "invalid folder structure. Working directory: '#{working_dir}', repository: '#{repository}', resulting path: '#{repo_dir}'"
      end
      raise "repository does not exist. Path: '#{repo_dir}'" unless File.directory?(repo_dir)

      # Assumes no password required. Re-clone if this has changed.
      io = IO::Memory.new
      result = 1

      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      repo_operation(repo_dir) do
        result = Process.run(
          "./bin/exec_from",
          {repo_dir, "git", "pull"},
          {"GIT_TERMINAL_PROMPT" => "0"},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_status % 256
      end

      {
        exit_status: result,
        output:      io.to_s,
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

      io = IO::Memory.new
      result = 1

      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      repo_lock(repo_dir).write do
        # Ensure the repository directory exists (it should)
        Dir.mkdir_p working_dir

        # Check if there's an existing repo
        if Dir.exists?(File.join(working_dir, repository, ".git"))
          io << "already exists"
          result = 0
        else
          # Ensure the cloned into directory does not exist
          Process.run("./bin/exec_from",
            {working_dir, "rm", "-rf", repository},
            input: Process::Redirect::Close,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close
          ) if Dir.exists?(File.join(working_dir, repository))

          # Clone the repository
          result = Process.run(
            "./bin/exec_from",
            {working_dir, "git", "clone", repository_uri, repository},
            {"GIT_TERMINAL_PROMPT" => "0"},
            input: Process::Redirect::Close,
            output: io,
            error: io
          ).exit_status
        end
      end

      {
        exit_status: result % 256,
        output:      io.to_s,
      }
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
      io = IO::Memory.new
      repo_lock(repository).write do
        operation_lock(repository).synchronize do
          # reset incase of a crash during a file operation
          result = Process.run(
            "./bin/exec_from", {repository, "git", "reset", "--hard"},
            input: Process::Redirect::Close,
            output: io,
            error: Process::Redirect::Close
          ).exit_status

          exit_status = result % 256
          raise CommandFailure.new(exit_status, "git reset --hard failed with #{exit_status} in path #{repository}") if exit_status != 0
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
