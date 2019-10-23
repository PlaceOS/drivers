require "./application"

module ACAEngine::Drivers::Api
  class Build < Application
    # list the available files
    def index
      compiled = params["compiled"]?
      if compiled
        render json: ACAEngine::Drivers::Compiler.compiled_drivers
      else
        result = [] of String
        Dir.cd(get_repository_path) do
          Dir.glob("drivers/**/*.cr") do |file|
            result << file unless file.ends_with?("_spec.cr")
          end
        end
        render json: result
      end
    end

    def show
      driver_source = URI.decode(params["id"])
      render json: ACAEngine::Drivers::Compiler.compiled_drivers(driver_source)
    end

    # grab the list of available repositories
    get "/repositories" do
      render json: ACAEngine::Drivers::Compiler.repositories
    end

    # grab the list of available versions of file / which are built
    get "/:id/commits" do
      driver_source = URI.decode(params["id"])
      count = (params["count"]? || 50).to_i

      render json: ACAEngine::Drivers::GitCommands.commits(driver_source, count, get_repository_path)
    end

    # Commits at repo level
    get "/repository_commits" do
      count = (params["count"]? || 50).to_i
      render json: ACAEngine::Drivers::GitCommands.repository_commits(get_repository_path, count)
    end

    # build a drvier, optionally based on the version specified
    def create
      driver = params["driver"]
      commit = params["commit"]? || "head"

      result = ACAEngine::Drivers::Compiler.build_driver(driver, commit, get_repository_path)

      if result[:exit_status] == 0
        render :not_acceptable, text: result[:output] unless File.exists?(result[:executable])
      else
        render :not_acceptable, text: result[:output]
      end

      response.headers["Location"] = "/build/#{URI.encode(driver)}"
      head :created
    end

    # delete a built driver
    def destroy
      driver_source = URI.decode(params["id"])
      commit = params["commit"]?

      # Check repository to prevent abuse (don't want to delete the wrong thing)
      repository = get_repository_path
      ACAEngine::Drivers::GitCommands.checkout(driver_source, commit || "head", repository) do
        head :not_found unless File.exists?(File.join(repository, driver_source))
      end

      files = if commit
                [Compiler.executable_name(driver_source, commit)]
              else
                ACAEngine::Drivers::Compiler.compiled_drivers(driver_source)
              end

      files.each do |file|
        File.delete File.join(ACAEngine::Drivers::Compiler.bin_dir, file)
      end
      head :ok
    end
  end
end
