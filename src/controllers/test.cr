class Test < Application
  before_action :ensure_driver_compiled, only: [:run_spec, :create]
  before_action :ensure_spec_compiled, only: [:run_spec, :create]
  @driver_path : String = ""
  @spec_path : String = ""

  ACA_DRIVERS_DIR = "../../#{Dir.current.split("/")[-1]}"

  # Specs available
  def index
    result = EngineDrivers::GitCommands.ls(get_repository_path)
    render json: result.select { |file|
      file.ends_with?("_spec.cr") && file.starts_with?("drivers/")
    }
  end

  # grab the list of available versions of the spec file
  get "/commits" do
    spec = params["spec"]
    count = (params["count"]? || 50).to_i

    render json: EngineDrivers::GitCommands.commits(spec, count, get_repository_path)
  end

  # Run the spec and return success if the exit status is 0
  def create
    io = IO::Memory.new
    exit_status = Process.run(
      @spec_path,
      {"--no-color"},
      {"SPEC_RUN_DRIVER" => @driver_path},
      input: Process::Redirect::Close,
      output: io,
      error: io
    ).exit_status

    render :not_acceptable, text: io.to_s if exit_status != 0
    render text: io.to_s
  end

  # WS watch the output from running specs
  ws "/run_spec", :run_spec do |socket|
    # Run the spec and pipe all the IO down the websocket
    spawn pipe_spec(socket, @spec_path, @driver_path)
  end

  def pipe_spec(socket, spec_path, driver_path)
    # TODO::
    socket.close
  end

  def ensure_driver_compiled
    driver = params["driver"]
    repository = get_repository_path
    commit = params["commit"]? || "head"

    driver_path = EngineDrivers::Compiler.is_built?(driver, commit, repository)

    # Build the driver if has not been compiled yet
    debug = params["debug"]?
    if driver_path.nil? || params["force"]? || debug
      result = EngineDrivers::Compiler.build_driver(driver, commit, repository, debug: !!debug)
      render :not_acceptable, text: result[:output] if result[:exit_status] != 0

      driver_path = EngineDrivers::Compiler.is_built?(driver, commit, repository)
    end

    # raise an error if the driver still does not exist
    @driver_path = driver_path.not_nil!
  end

  def ensure_spec_compiled
    spec = params["spec"]
    repository = get_repository_path
    spec_commit = params["spec_commit"]? || "head"

    spec_path = EngineDrivers::Compiler.is_built?(spec, spec_commit, repository)

    debug = params["debug"]?
    if spec_path.nil? || params["force"]? || debug
      result = EngineDrivers::Compiler.build_driver(spec, spec_commit, repository, debug: !!debug)
      render :not_acceptable, text: result[:output] if result[:exit_status] != 0

      spec_path = EngineDrivers::Compiler.is_built?(spec, spec_commit, repository)
    end

    @spec_path = spec_path.not_nil!
  end
end
