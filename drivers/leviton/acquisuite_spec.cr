require "placeos-driver/spec"

DriverSpecs.mock_driver "Leviton::Acquisuite" do
  headers = {"Content-Type" => ["multipart/form-data; boundary=MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY"]}
  test_devices = ["mb-001"]

  # First, we need to receive some failed LOGFILEUPLOAD requests to work out our list of devices
  test_devices.each do |device_name|
    dev_log = File.read("/app/repositories/local/drivers/leviton/#{device_name}.63BD5AFD_2.log.gz")
    body = create_request(
      "LOGFILEUPLOAD",
      "Temp Inputs / Branch Circuits",
      device_name[-1].to_s,
      "9a6d278642b64db73c754271de733758",
      "2022-09-12 21:25:55",
      "LOGFILE",
      "modbus/#{device_name}.63BD5AFD_2.log.gz",
      nil
    )
    body = body.gsub("\n", "\r\n")
    body = body.gsub("fileplaceholder", dev_log)
    resp = exec(:receive_webhook, "POST", headers, Base64.encode(body)).get

    res = exec(:device_list).get
    res = res.not_nil!
    res = Hash(String, Array(String)).from_json(res.to_json)
    res.keys.any? { |device| device.includes?(device_name) }.should be_true if !res.nil?
  end

  # Next we receive a CONFIGFILEMANIFEST webhook asking for the config files we want
  body = <<-BODY

  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MODE"
  
  CONFIGFILEMANIFEST
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY--
  BODY

  body = body.gsub("\n", "\r\n")
  resp = exec(:receive_webhook, "POST", headers, Base64.encode(body)).get

  # We should expect the driver to respond with a manifest containing the list of devices
  resp = resp.not_nil!
  # resp[2].to_s.split("\n").size.should eq device_list.size if !resp.nil?

  dev_config = File.read("/app/repositories/local/drivers/leviton/mb-001.ini")

  # Then we receive a CONFIGFILEMANIFEST webhook asking for the config files we want
  body = create_request(
    "CONFIGFILEUPLOAD",
    "Temp Inputs / Branch Circuits",
    "1",
    "9a6d278642b64db73c754271de733758",
    "2022-09-12 21:25:55",
    "CONFIGFILE",
    "modbus/mb-001.ini",
    dev_config
  )

  body = body.gsub("\n", "\r\n")
  resp = exec(:receive_webhook, "POST", headers, Base64.encode(body)).get

  dev_log = File.read("/app/repositories/local/drivers/leviton/mb-001.63BD5AFD_2.log.gz")

  # Now, finally, send an actual log file
  body = create_request(
    "LOGFILEUPLOAD",
    "Temp Inputs / Branch Circuits",
    "1",
    "9a6d278642b64db73c754271de733758",
    "2022-09-12 21:25:55",
    "LOGFILE",
    "mb-001.63BD5AFD_2.log.gz",
    nil
  )
  body = body.gsub("\n", "\r\n")
  body = body.gsub("fileplaceholder", dev_log)
  resp = exec(:receive_webhook, "POST", headers, Base64.encode(body)).get
end

# Some of these fields may not be present in every request but
# having them there doesn't hurt anything so why bother removing them
def create_request(mode : String, device_name : String, modbus_device : String, md5 : String, file_time : String, file_descriptor : String, file_name : String, file : String?)
  file = "fileplaceholder" if file.nil?
  <<-BODY
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MODE"

  #{mode}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MODBUSDEVICENAME"

  #{device_name}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MODBUSDEVICE"

  #{modbus_device}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MD5CHECKSUM"

  #{md5}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="FILETIME"

  #{file_time}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="#{file_descriptor}"; filename="#{file_name}"
  Content-Type: application/octet-stream;

  #{file}
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY--

  BODY
end
