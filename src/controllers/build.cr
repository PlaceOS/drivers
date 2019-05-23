class Build < Application
  # list the available files
  def index
    compiled = params["compiled"]?
    repository = params["repository"]? || EngineDrivers::Compiler.drivers_dir

    list = if compiled
             EngineDrivers::Compiler.compiled_drivers
           else
             result = EngineDrivers::GitCommands.ls(repository)

             render json: result.select { |file|
               file.ends_with?(".cr") && !file.ends_with?("_spec.cr") && file.starts_with?("drivers/")
             }
           end

    render json: list
  end

  def show
    driver = URI.unescape(params["id"])
    render json: EngineDrivers::Compiler.compiled_drivers(driver)
  end

  # grab the list of available versions of file / which are built
  get "/commits" do
    driver = params["driver"]
    count = (params["count"]? || 50).to_i
    repository = params["repository"]? || EngineDrivers::Compiler.drivers_dir

    render json: EngineDrivers::GitCommands.commits(driver, count, repository)
  end

  # build a drvier, optionally based on the version specified
  def create
    driver = params["driver"]
    commit = params["commit"]? || "head"
    repository = params["repository"]? || EngineDrivers::Compiler.drivers_dir

    result = EngineDrivers::Compiler.build_driver(driver, commit, repository)

    if result[:exit_status] != 0
      render :not_acceptable, text: result[:output]
    end

    head :created
  end

  # delete a built driver
  def destroy
    driver = URI.unescape(params["id"])
    commit = params["commit"]?

    # Check repository to prevent abuse (don't want to delete the wrong thing)
    repository = params["repository"]? || EngineDrivers::Compiler.drivers_dir
    EngineDrivers::GitCommands.checkout(driver, commit || "head", repository) do
      head :not_found unless File.exists?(File.join(repository, driver))
    end

    files = if commit
              exec_name = driver.gsub(/\/|\./, "_")
              ["#{exec_name}_#{commit}"]
            else
              EngineDrivers::Compiler.compiled_drivers(driver)
            end

    files.each do |file|
      File.delete File.join(EngineDrivers::Compiler::BIN_DIR, file)
    end
    head :ok
  end
end
