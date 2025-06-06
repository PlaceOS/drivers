require "http"
require "placeos-driver"
require "csv"
require "action-controller/body_parser"
require "compress/gzip"

class Leviton::Acquisuite < PlaceOS::Driver
  descriptive_name "Leviton Acquisuite Webhook"
  generic_name :Leviton
  description %(provide an endpoint for the Leviton webhook to send logfiles)

  default_settings({
    device_list:   {"loggerconfig.ini" => {"X", "0000-00-00 00:00:00"}},
    manifest_list: [] of String,
    config_list:   {} of String => Array(Hash(String, Float64 | String | Nil)),
    debug_webhook: false,
  })
  #
  @debug_webhook : Bool = false
  @device_list : Hash(String, Tuple(String, String)) = {} of String => Tuple(String, String)
  @manifest_list : Array(String) = [] of String
  @config_list : Hash(String, Array(Hash(String, Float64 | String | Nil))) = {} of String => Array(Hash(String, Float64 | String | Nil))

  def on_update
    @debug_webhook = setting?(Bool, :debug_webhook) || false
    @device_list = setting(Hash(String, Tuple(String, String)), :device_list)
    @manifest_list = setting(Array(String), :manifest_list)
    @config_list = setting(Hash(String, Array(Hash(String, Float64 | String | Nil))), :config_list)
  end

  def receive_webhook(method : String, headers : Hash(String, Array(String)), body : String)
    logger.warn do
      "Received Webhook\n" +
        "Method: #{method.inspect}\n" +
        "Headers:\n#{headers.inspect}\n" +
        "Body:\n#{body.inspect}"
    end if @debug_webhook
    decoded = Base64.decode_string(body)
    case method.downcase
    when "post"
      new_headers = HTTP::Headers.new
      headers.each { |k, v| new_headers[k] = v }
      request = HTTP::Request.new("POST", "/request", new_headers, decoded)
      files, form_data = ActionController::BodyParser.extract_form_data(request, "multipart/form-data", request.query_params)
      form_data = form_data.not_nil!
      case form_data["MODE"]
      # This is the server checking the status of our webhook so just 200 back
      when "STATUS"
        return {HTTP::Status::OK.to_i, {} of String => String, "SUCCESS"}
        # This is the server asking for a list of devices which we need the config files
      when "CONFIGFILEMANIFEST"
        return {HTTP::Status::OK.to_i, {} of String => String, device_to_manifest.join("\n")}
        # This is the server sending us an actual config file from the previously provided list
      when "CONFIGFILEUPLOAD"
        files = files.not_nil!
        return config_file_upload(files, form_data)
        # Finally, this is an actual log file from a device that we should already have the config file for
      when "LOGFILEUPLOAD"
        files = files.not_nil!
        return log_file_upload(files, form_data)
      else
        {HTTP::Status::INTERNAL_SERVER_ERROR.to_i, {"Content-Type" => "application/json"}, "FAILURE: Invalid mode passed. Either STATUS, CONFIGFILEMANIFEST, CONFIGFILEUPLOAD or LOGFILEUPLOAD required. Got #{form_data["MODE"]}"}
      end
    end
  rescue error
    logger.warn(exception: error) { "processing webhook request: #{body.inspect}" }
    self[:last_error] = error.inspect_with_backtrace
    self[:error_payload] = body
    {HTTP::Status::INTERNAL_SERVER_ERROR.to_i, {"Content-Type" => "application/json"}, "FAILURE: #{error.message.to_s}"}
  end

  protected def log_file_upload(files : Hash(String, Array(ActionController::BodyParser::FileUpload)), form_data : URI::Params)
    log_file, log_contents = get_file(files, "LOGFILE")
    # Check whether we have the config for this log file device type
    modbus_index = form_data["MODBUSDEVICE"].to_i
    if !@device_list.any? { |device, config| device.includes?("mb-%03d" % modbus_index) && config[0] != "X" }
      # Add this device to our device list
      @device_list["mb-%03d.ini" % modbus_index] = {"X", "0000-00-00 00:00:00"}
      define_setting(:device_list, @device_list)
      return {HTTP::Status::NOT_ACCEPTABLE.to_i, {} of String => String, "FAILURE: Device list invalid"}
    end
    return if log_contents.nil?
    csv = CSV.new(log_contents, headers: true)
    # NOTE: This csv.next structure assumes that there will be a header row we don't need
    # if this is not the case we should add logic to check for a header
    while csv.next
      data = [] of Hash(String, (String | Int64 | Float64))
      @config_list[form_data["MODBUSDEVICE"]].each_with_index do |conf, i|
        next if @config_list[form_data["MODBUSDEVICE"]][i]["NAME"] == "-\r"
        # Disregard the first 4 columns of the csv
        csv_index = i + 4
        next if csv[csv_index].rstrip == ""
        time = Time.parse(csv[0].gsub("'", "").strip, "%Y-%m-%d %H:%M:%S", Time::Location::UTC).to_unix
        reading = {
          "time"  => time,
          "name"  => @config_list[form_data["MODBUSDEVICE"]][i]["NAME"].as(String).rstrip,
          "units" => @config_list[form_data["MODBUSDEVICE"]][i]["UNITS"].as(String).rstrip,
        } of String => (String | Int64 | Float64)
        begin
          reading["value"] = csv[csv_index].rstrip.to_f
        rescue ex : ArgumentError
          reading["reading"] = csv[csv_index].rstrip
        end
        data << reading
      end
      self["mb-%03d" % modbus_index] = {
        value:        data,
        ts_hint:      "complex",
        ts_timestamp: "time",
        measurement:  "acquisuite",
      }
    end
    {HTTP::Status::OK.to_i, {} of String => String, "SUCCESS"}
  end

  protected def config_file_upload(files : Hash(String, Array(ActionController::BodyParser::FileUpload)), form_data : URI::Params)
    config_file, config_contents = get_file(files, "CONFIGFILE")

    # First update our manifest with the new config data
    @device_list["mb-%03d.ini" % form_data["MODBUSDEVICE"].to_i] = {form_data["MD5CHECKSUM"], form_data["FILETIME"]}

    # Below is an alternative way of saving that we can only really verify once real data is hooked up
    # @device_list[config_contents.filename] = {form_data["MD5CHECKSUM"],form_data["FILETIME"]}

    define_setting(:device_list, @device_list)

    # Now update our config list with the new config
    store_config(form_data["MODBUSDEVICE"], config_contents) unless config_contents.nil?
    {HTTP::Status::OK.to_i, {} of String => String, "SUCCESS"}
  end

  protected def get_file(files : Hash(String, Array(ActionController::BodyParser::FileUpload)), name : String)
    file = files.not_nil!
    file_object = file[name][0]
    file_contents = file_object.body.gets_to_end
    # If the file is gzipped then unzip it
    file_name = file_object.filename
    if file_name && file_name[-3..-1] == ".gz"
      file_unzipped = Compress::Gzip::Reader.open(IO::Memory.new(file_contents)) do |gzip|
        gzip.gets_to_end
      end
    else
      file_unzipped = file_contents
    end
    {file_object, file_unzipped}
  end

  def device_list
    @device_list
  end

  protected def store_config(modbusid : String, config : String)
    index_max = config.split("\n").map { |line|
      reg = /POINT(?<index>\d+)(?<name>.*)=(?<value>.*)/.match(line)
      reg[1].to_i if reg
    }.compact.sort.pop

    configs = Array.new(index_max + 1, {} of String => (Float64 | String | Nil))

    config.split("\n").each do |line|
      reg = /POINT(?<index>\d+)(?<name>.*)=(?<value>.*)/.match(line)
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
  protected def device_to_manifest
    @device_list.map { |name, data| "CONFIGFILE,modbus/#{name},#{data[0]},#{data[1]}" }
  end
end
