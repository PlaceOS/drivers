class EngineDrivers::GitCommands
  # Will really only be an issue once threads come along
  @@lock_manager = Mutex.new

  # Allow multiple file level operations to occur in parrallel
  # File level operations are readers, repo level are writers
  @@repository_lock = {} of String => ReadersWriterLock

  # Ensure only a single git operation is occuring at once to avoid corruption
  @@operation_lock = {} of String => Mutex

  # Ensures only a single operation on an individual file occurs at once
  # This enables multi-version compilation to occur without clashing
  @@file_lock = {} of String => Hash(String, Mutex)

  def self.ls(repository = EngineDrivers::Compiler.drivers_dir)
    io = IO::Memory.new
    result = basic_operation(repository) do
      Process.run(
        "./bin/exec_from", {repository, "git", "--no-pager", "ls-files"},
        input: Process::Redirect::Close,
        output: io,
        error: Process::Redirect::Close
      )
    end

    raise CommandFailure.new(result.exit_status) if result.exit_status != 0

    io.to_s.split("\n")
  end

  def self.commits(file_name, count = 10, repository = EngineDrivers::Compiler.drivers_dir)
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

    raise CommandFailure.new(result.exit_status) if result.exit_status != 0

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

  def self.checkout(file, commit = "head", repository = EngineDrivers::Compiler.drivers_dir)
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
        raise CommandFailure.new(result.exit_status) if result.exit_status != 0

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

  def self.clone(repository, repository_uri, username = nil, password = nil, working_dir = "../repositories")
    # Ensure we are rm -rf a sane folder - don't want to delete root for example
    unless repository.starts_with?(working_dir) && working_dir.size > 1 && (repository.size - working_dir.size) > 1
      raise "invalid folder structure. Working directory: '#{working_dir}', repository: '#{repository}'"
    end

    io = IO::Memory.new
    result = 1

    if username && password
      # remove the https://
      uri = repository_uri[8..-1]
      # rebuild URL
      repository_uri = "https://#{username}:#{password}@#{uri}"
    end

    # Ensure the repository directory exists (it should)
    Dir.mkdir_p working_dir

    # The call to write here ensures that no other operations are occuring on
    # the repository at this time.
    repo_lock(repository).write do
      # Ensure the repository being cloned does not exist
      Process.run("./bin/exec_from",
        {working_dir, "rm", "-rf", repository},
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      result = Process.run(
        "./bin/exec_from",
        {working_dir, "git", "clone", repository_uri, repository},
        {"GIT_TERMINAL_PROMPT" => "0"},
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

  def self.basic_operation(repository)
    repo_lock(repository).read do
      operation_lock(repository).synchronize { yield }
    end
  end

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
        locks[file] = Mutex.new
      end
    end
  end

  def self.repo_lock(repository) : ReadersWriterLock
    @@lock_manager.synchronize do
      if lock = @@repository_lock[repository]?
        lock
      else
        @@repository_lock[repository] = ReadersWriterLock.new
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
