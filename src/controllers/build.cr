class Build < Application
  # list the available files
  def index
    compiled = params["compiled"]?
    list = if compiled
             EngineDrivers::Compiler.compiled_drivers
           else
             result = EngineDrivers::GitCommands.ls

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

    render json: EngineDrivers::GitCommands.commits(driver, count)
  end

  # build a drvier, optionally based on the version specified
  def create
    driver = params["driver"]
    commit = params["commit"]? || "head"

    head :not_found unless File.exists?(driver)

    result = EngineDrivers::GitCommands.checkout(driver, commit) do
      # complile the driver
      EngineDrivers::Compiler.build_driver(driver)
    end

    if result[:exit_status] != 0
      render :not_acceptable, text: result[:output]
    end

    head :created
  end

  # delete a built driver
  def destroy
    driver = URI.unescape(params["id"])
    commit = params["commit"]?

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
