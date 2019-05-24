class Build < Application
  # list the available files
  def index
    compiled = params["compiled"]?
    list = if compiled
             EngineDrivers::Compiler.compiled_drivers
           else
             result = EngineDrivers::GitCommands.ls(get_repository_path)
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

  # grab the list of available repositories
  get "/repositories" do
    EngineDrivers::Compiler.repositories
  end

  # grab the list of available versions of file / which are built
  get "/commits" do
    driver = params["driver"]
    count = (params["count"]? || 50).to_i

    render json: EngineDrivers::GitCommands.commits(driver, count, get_repository_path)
  end

  # build a drvier, optionally based on the version specified
  def create
    driver = params["driver"]
    commit = params["commit"]? || "head"

    result = EngineDrivers::Compiler.build_driver(driver, commit, get_repository_path)

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
    repository = get_repository_path
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

  protected def get_repository_path
    repository = params["repository"]?
    if repository
      repo = File.expand_path(File.join(EngineDrivers::Compiler.repository_dir, repository))
      valid = repo.starts_with?(EngineDrivers::Compiler.repository_dir) && repo != "/" && repository.size > 0 && !repository.includes?("/") && !repository.includes?(".")
      raise "invalid repository: #{repository}" unless valid
      repo
    else
      EngineDrivers::Compiler.drivers_dir
    end
  end
end
