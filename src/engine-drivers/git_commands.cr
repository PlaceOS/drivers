class EngineDrivers::GitCommands
  def self.ls
    io = IO::Memory.new
    result = Process.run(
      "git", {"--no-pager", "ls-files"},
      input: Process::Redirect::Close,
      output: io,
      error: Process::Redirect::Close
    )

    raise CommandFailure.new(result.exit_status) if result.exit_status != 0

    io.to_s.split("\n")
  end

  def self.commits(file_name, count = 10)
    io = IO::Memory.new

    # https://git-scm.com/docs/pretty-formats
    # %h: abbreviated commit hash
    # %cI: committer date, strict ISO 8601 format
    # %an: author name
    # %s: subject
    result = Process.run(
      "git", {"--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s, file_name},
      input: Process::Redirect::Close,
      output: io,
      error: Process::Redirect::Close
    )

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

  def self.checkout(file, commit = "head")
    # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
    result = Process.run("git", {"checkout", commit, "--", file})
    raise CommandFailure.new(result.exit_status) if result.exit_status != 0

    yield file

    # reset the file back to head
    Process.run("git", {"checkout", "--", file})
  end
end
