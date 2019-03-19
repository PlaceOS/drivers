class Build < Application
  # list the available files
  def index
    io = IO::Memory.new
    result = Process.run(
      "git", {"ls-files"},
      input: Process::Redirect::Close,
      output: io,
      error: Process::Redirect::Close
    )

    head :internal_server_error if result.exit_status != 0

    render json: io.to_s.split("\n").select { |file|
      file.ends_with?(".cr") && !file.ends_with?("_spec.cr") && file.starts_with?("drivers/")
    }
  end

  # grab the list of available versions of file / which are built
  get "/commits" do
    driver = params["driver"]
    count = params["id"]

    io = IO::Memory.new
    result = Process.run(
      "git", {"-no-pager", "log", "--format=short", "--no-color", "-n", count, driver},
      input: Process::Redirect::Close,
      output: io,
      error: Process::Redirect::Close
    )

    head :internal_server_error if result.exit_status != 0

    commits = io.to_s.split("commit ").reject(&.empty?).map(&.split("\n", 3).map &.strip)
    commits.map! do |commit|
      {
        commit:  commit[0],
        author:  commit[1].split(" ", 2)[1],
        message: commit[2],
      }
    end
    render json: commits
  end

  # build a drvier, optionally based on the version specified
  def create
    driver = params["driver"]
    commit = params["commit"]? || "head"

    # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
    result = Process.run("git", {"checkout", commit, "--", driver})
    head :internal_server_error if result.exit_status != 0

    # complile the driver
    # TODO::

    # reset the file back to head
    Process.run("git", {"checkout", "--", driver})
    head :ok
  end

  # delete a built driver
  def delete
  end
end
