class Test < Application
  before_action :ensure_driver_compiled, only: [:run_spec, :create]
  @driver_path : String?

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
  end

  # WS watch the output from running specs
  ws "/run_spec", :run_spec do |socket|
    spec = params["spec"]
    repository = get_repository_path
    spec_commit = params["spec_commit"]? || "head"

    # Run the spec and pipe all the IO down the websocket

  end

  def ensure_driver_compiled
    driver = params["driver"]
    repository = get_repository_path
    commit = params["commit"]? || "head"

    driver_path = EngineDrivers::Compiler.is_built?(driver, commit, repository)

    # Build the driver if has not been compiled yet
    if driver_path.nil?
      result = EngineDrivers::Compiler.build_driver(driver, commit, get_repository_path)
      render :not_acceptable, text: result[:output] if result[:exit_status] != 0

      driver_path = EngineDrivers::Compiler.is_built?(driver, commit, repository)
    end

    # raise an error if the driver still does not exist
    @driver_path = driver_path.not_nil!
  end
end
