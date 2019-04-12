class EngineDrivers::GitCommands
  @@lock_manager = Mutex.new

  # Ensure only a single git operation is occuring at once to avoid corruption
  @@repository_lock = {} of String => Mutex

  # Ensures only a single operation on an individual file occurs at once
  # This enables multi-version compilation to occur without clashing
  @@file_lock = {} of String => Mutex

  def self.ls(repository = EngineDrivers::Compiler.drivers_dir)
    io = IO::Memory.new
    result = get_lock(repository).synchronize do
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
    result = get_lock(repository).synchronize do
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
    repo_lock = get_lock(repository)

    get_lock(repository, file).synchronize do
      result = repo_lock.synchronize do
        Process.run(
          "./bin/exec_from",
          {repository, "git", "checkout", commit, "--", file}
        )
      end
      raise CommandFailure.new(result.exit_status) if result.exit_status != 0

      yield file

      # reset the file back to head
      repo_lock.synchronize do
        Process.run(
          "./bin/exec_from",
          {repository, "git", "checkout", "--", file}
        )
      end
    end
  end

  def self.clone(repository, repository_uri, username = nil, password = nil)
    io = IO::Memory.new
    result = 1

    if username && password
      # remove the https://
      uri = repository_uri[8..-1]
      # rebuild URL
      repository_uri = "https://#{username}:#{password}@#{uri}"
    end

    # Ensure the repository directory exists (it should)
    working_dir = "../repositories"
    Dir.mkdir_p working_dir

    get_lock(repository).synchronize do
      # Ensure the repository being cloned does not exist
      # TODO:: Process run rm -rf folder

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

  def self.get_lock(repository) : Mutex
    @@lock_manager.synchronize do
      if lock = @@repository_lock[repository]?
        lock
      else
        lock = Mutex.new
        @@repository_lock[repository] = lock
        lock
      end
    end
  end

  def self.get_lock(repository, file) : Mutex
    lock_key = "#{repository}`#{file}"
    @@lock_manager.synchronize do
      if lock = @@file_lock[lock_key]?
        lock
      else
        lock = Mutex.new
        @@file_lock[lock_key] = lock
        lock
      end
    end
  end
end
