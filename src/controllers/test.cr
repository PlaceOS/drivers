require "./application"

module PlaceOS::Drivers::Api
  class Test < Application
    base "/test"

    before_action :ensure_driver_compiled, only: [:run_spec, :create]
    before_action :ensure_spec_compiled, only: [:run_spec, :create]
    @driver_path : String = ""
    @spec_path : String = ""

    PLACE_DRIVERS_DIR = "../../#{Dir.current.split("/")[-1]}"

    # Specs available
    def index
      result = [] of String
      Dir.cd(get_repository_path) do
        Dir.glob("drivers/**/*_spec.cr") { |file| result << file }
      end
      render json: result
    end

    # grab the list of available versions of the spec file
    get "/:id/commits" do
      spec = URI.decode(params["id"])
      count = (params["count"]? || 50).to_i

      render json: Compiler::GitCommands.commits(spec, count, get_repository_path)
    end

    # Run the spec and return success if the exit status is 0
    def create
      debug = params["debug"]? == "true"

      io = IO::Memory.new
      exit_code = launch_spec(io, debug)

      render :not_acceptable, text: io.to_s if exit_code != 0
      render text: io.to_s
    end

    # WS watch the output from running specs
    ws "/run_spec", :run_spec do |socket|
      debug = params["debug"]? == "true"

      # Run the spec and pipe all the IO down the websocket
      spawn { pipe_spec(socket, debug) }
    end

    def pipe_spec(socket, debug)
      output, output_writer = IO.pipe
      spawn { launch_spec(output_writer, debug) }

      # Read data coming in from the IO and send it down the websocket
      raw_data = Bytes.new(1024)
      begin
        while !output.closed?
          bytes_read = output.read(raw_data)
          break if bytes_read == 0 # IO was closed
          socket.send String.new(raw_data[0, bytes_read])
        end
      rescue IO::Error
        # Input stream closed. This should only occur on termination
      end

      # Once the process exits, close the websocket
      socket.close
    end

    GDB_SERVER_PORT = ENV["GDB_SERVER_PORT"]? || "4444"

    def launch_spec(io, debug)
      io << "\nLaunching spec runner\n"

      if debug
        exit_code = Process.run(
          "gdbserver",
          {"0.0.0.0:#{GDB_SERVER_PORT}", @spec_path},
          {"SPEC_RUN_DRIVER" => @driver_path},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_code
        io << "spec runner exited with #{exit_code}\n"
        io.close
        exit_code
      else
        exit_code = Process.run(
          @spec_path,
          nil,
          {"SPEC_RUN_DRIVER" => @driver_path},
          input: Process::Redirect::Close,
          output: io,
          error: io
        ).exit_code
        io << "spec runner exited with #{exit_code}\n"
        io.close
        exit_code
      end
    end

    def ensure_driver_compiled
      driver = params["driver"]
      repository = get_repository_path
      commit = params["commit"]? || "HEAD"

      driver_path = Compiler.is_built?(driver, commit, repository)

      # Build the driver if has not been compiled yet
      debug = params["debug"]?
      if driver_path.nil? || params["force"]? || debug
        result = Compiler.build_driver(driver, commit, repository, debug: !!debug)
        output = result[:output].strip

        render :not_acceptable, text: output if result[:exit_status] != 0 || !File.exists?(result[:executable])

        driver_path = Compiler.is_built?(driver, commit, repository)
      end

      # raise an error if the driver still does not exist
      @driver_path = driver_path.not_nil!
    end

    def ensure_spec_compiled
      spec = params["spec"]
      repository = get_repository_path
      spec_commit = params["spec_commit"]? || "HEAD"

      spec_path = Compiler.is_built?(spec, spec_commit, repository)

      debug = params["debug"]?
      if spec_path.nil? || params["force"]? || debug
        result = Compiler.build_driver(spec, spec_commit, repository, debug: !!debug)
        output = result[:output].strip

        render :not_acceptable, text: output if result[:exit_status] != 0 || !File.exists?(result[:executable])

        spec_path = Compiler.is_built?(spec, spec_commit, repository)
      end

      @spec_path = spec_path.not_nil!
    end
  end
end
