require "http"
require "placeos-driver"
require "csv"
require "action-controller/body_parser"

class Leviton::Acquisuite < PlaceOS::Driver
  descriptive_name "Leviton Acquisuite Webhook"
  generic_name :LevitonAcquisuite
  description %(provide an endpoint for the Leviton webhook to send logfiles)

  default_settings({
    device_list: ["loggerconfig.ini"],
    manifest_list: [] of String,
    config_list: {} of String => Array(Hash(String, Float64 | String)),
    debug_webhook: false
  })

  @debug_webhook : Bool = false
  @device_list : Array(String) = [] of String
  @manifest_list : Array(String) = [] of String
  @config_list : Hash(String, Array(Hash(String, Float64 | String))) = {} of String => Array(Hash(String, Float64 | String))
  
  def on_load
    on_update
  end

  def on_update
    @debug_webhook = setting?(Bool, :debug_webhook) || false
    @device_list = setting(Array(String), :device_list)
    @manifest_list = setting(Array(String), :manifest_list)
  end

  def request(method : String, headers : Hash(String, Array(String)), body : String)

    case method.downcase
    when "post"
      new_headers = HTTP::Headers.new
      headers.each {|k,v| new_headers[k] = v }
      request = HTTP::Request.new("POST", "/request", new_headers, body)
      files, form_data = ActionController::BodyParser.extract_form_data(request, "multipart/form-data", request.query_params)
      form_data = form_data.not_nil!
      case form_data["MODE"]
        when "CONFIGFILEMANIFEST"
          if @manifest_list.empty?
            # If the manifest list is empty then we need to create our own for first run
            manifest = device_to_manifest
          else
            # Otherwise send our existing manifest list
            manifest = @manifest_list
          end
          {HTTP::Status::OK.to_i, {} of String => String, manifest.join("\n")}
        when "CONFIGFILEUPLOAD"
          file = files.not_nil!
          config_contents = file["CONFIGFILE"][0]
          config_file = config_contents.body.gets_to_end

          # First update our manifest with the new config data
          @manifest_list << "CONFIGFILE,#{config_contents.filename},#{form_data["MD5CHECKSUM"]},#{form_data["FILETIME"]}"
          define_setting(:manifest_list, @manifest_list)

          # Now update our config list with the new config
          store_config(form_data["MODBUSDEVICE"], config_file)
        when "LOGFILEUPLOAD"
          file = files.not_nil!
          log_contents = file["LOGFILE"][0]
          log_file = log_contents.body.gets_to_end

          # logger.debug { "GOT LOGFILE" }
          # logger.debug { @config_list[form_data["MODBUSDEVICE"]] }
          csv = CSV.new(log_file, headers: true)

          logger.debug { "CSV RANDOM CHECK" }
          logger.debug { @config_list[form_data["MODBUSDEVICE"]] }
          logger.debug { @config_list[form_data["MODBUSDEVICE"]].size }
          logger.debug { @config_list[form_data["MODBUSDEVICE"]].class }
          data_line = [] of NamedTuple(time: Int64, data: Float64, name: String, units: String)
          # NOTE: This csv.next structure assumes that there will be a header row we don't need
          # if this is not the case we should add logic to check for a header 
          while csv.next
            @config_list[form_data["MODBUSDEVICE"]].each_with_index do |conf, i|
              next if @config_list[form_data["MODBUSDEVICE"]][i]["NAME"] == "-\r"
              csv_index = i + 3
              reading = {
                time: Time.parse(csv[0].gsub("'","").strip, "%Y-%m-%d %H:%M:%S", Time::Location::UTC).to_unix,
                data: csv[csv_index],
                name: @config_list[form_data["MODBUSDEVICE"]][i]["NAME"],
                units: @config_list[form_data["MODBUSDEVICE"]][i]["UNITS"]
              }
              self["mb-#{form_data["MODBUSDEVICE"]}"] = reading 
            end
          end
      end
      
    end
  rescue error
    logger.warn(exception: error) { "processing webhook request" }
    # {HTTP::Status::INTERNAL_SERVER_ERROR.to_i, {"Content-Type" => "application/json"}, error.message.to_s}
  end

  def store_config(modbusid : String, config : String)
    index_max = config.split("\n").map{ |line|
      reg = /POINT(?<index>\d*)(?<name>.*)=(?<value>.*)/.match(line)
      reg[1].to_i if reg
    }.compact.sort.pop
    
    configs = Array.new(index_max + 1, {} of String => (Float64 | String))
    
    config.split("\n").each do |line|
      reg = /POINT(?<index>\d*)(?<name>.*)=(?<value>.*)/.match(line)
      if reg
        config_index = reg[1].to_i
        column_header = reg[2]
        column_value = reg[3]
        begin
          column_value = column_value.to_f64
        rescue
        end
      new_obj = configs[config_index].dup
      new_obj[column_header] = column_value
      configs[config_index] = new_obj
      end
    end
    @config_list[modbusid] = configs
    define_setting(:config_list, @config_list)
  end

  # Converts the device list to the starting manifest format 
  def device_to_manifest
    @device_list.map{|d| "CONFIGFILE,#{d},X,0000-00-00 00:00:00"}
  end

end
