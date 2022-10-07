require "placeos-driver/spec"

DriverSpecs.mock_driver "Leviton::Acquisuite" do

  settings({
    debug_webhook: true,
    manifest_list: [] of String,
    device_list: [
      "loggerconfig.ini",
      "modbus/mb-001.ini"
    ],
    config_list: {} of String => Array(Hash(String, Float64 | String))
  })

  headers = {"Content-Type" => ["multipart/form-data; boundary=MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY"]}

  # First we receive a CONFIGFILEMANIFEST webhook asking for the config files we want
  body = <<-BODY

  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY
  Content-Disposition: form-data; name="MODE"
  
  CONFIGFILEMANIFEST
  --MIME_BOUNDRY_MIME_BOUNDRY_MIME_BOUNDRY--
  BODY

  body = body.gsub("\n", "\r\n")
  resp = exec(:request, "POST", headers, body).get

  # TODO:: Read this in from a file to keep this cleaner
  dev_config = <<-DEV_CONFIG
    POINT00NAME=ION6200
    POINT00UNITS=KWh
    POINT00LOW=0
    POINT00HIGH=0
    POINT00CONSOLE=YES
    POINT01NAME=ION6200 demand
    POINT01UNITS=kW
    POINT01LOW=0
    POINT01HIGH=0
    POINT01CONSOLE=YES
    POINT02NAME=ION6200 rate (instantaneous)
    POINT02UNITS=kW
    POINT02LOW=0
    POINT02HIGH=0
    POINT02CONSOLE=NO
    POINT03NAME=ION6200 rate min
    POINT03UNITS=kW
    POINT03LOW=0
    POINT03HIGH=0
    POINT03CONSOLE=NO
    POINT04NAME=ION6200 rate max
    POINT04UNITS=kW
    POINT04LOW=0
    POINT04HIGH=0
    POINT04CONSOLE=NO
    POINT05NAME=ION6200Reactive
    POINT05UNITS=KVARh
    POINT05LOW=0
    POINT05HIGH=0
    POINT05CONSOLE=NO
    POINT06NAME=ION6200Reactive demand
    POINT06UNITS=kVAR
    POINT06LOW=0
    POINT06HIGH=0
    POINT06CONSOLE=YES
    POINT07NAME=ION6200Reactive rate (instantaneous)
    POINT07UNITS=kVAR
    POINT07LOW=0
    POINT07HIGH=0
    POINT07CONSOLE=NO
    POINT08NAME=ION6200Reactive rate min
    POINT08UNITS=kVAR
    POINT08LOW=0
    POINT08HIGH=0
    POINT08CONSOLE=NO
    POINT09NAME=ION6200Reactive rate max
    POINT09UNITS=kVAR
    POINT09LOW=0
    POINT09HIGH=0
    POINT09CONSOLE=NO
    POINT10NAME=Apparent Power (demand)
    POINT10UNITS=KVA
    POINT10LOW=0
    POINT10HIGH=0
    POINT10CONSOLE=NO
    POINT11NAME=Apparent Power (instantaneous)
    POINT11UNITS=KVA
    POINT11LOW=0
    POINT11HIGH=0
    POINT11CONSOLE=NO
    POINT12NAME=Power Factor (demand)
    POINT12UNITS=
    POINT12LOW=0
    POINT12HIGH=0
    POINT12CONSOLE=NO
    POINT13NAME=Power Factor (instantaneous)
    POINT13UNITS=
    POINT13LOW=0
    POINT13HIGH=0
    POINT13CONSOLE=NO
    POINT14NAME=Water Meter
    POINT14UNITS=Gallons
    POINT14LOW=0
    POINT14HIGH=0
    POINT14CONSOLE=NO
    POINT15NAME=Water Meter rate
    POINT15UNITS=Gpm
    POINT15LOW=0
    POINT15HIGH=0
    POINT15CONSOLE=NO
    POINT16NAME=Water Meter rate (instantaneous)
    POINT16UNITS=Gpm
    POINT16LOW=0
    POINT16HIGH=0
    POINT16CONSOLE=NO
    POINT17NAME=Water Meter rate min
    POINT17UNITS=Gpm
    POINT17LOW=0
    POINT17HIGH=0
    POINT17CONSOLE=NO
    POINT18NAME=Water Meter rate max
    POINT18UNITS=Gpm
    POINT18LOW=0
    POINT18HIGH=0
    POINT18CONSOLE=NO
    POINT19NAME=Gas Meter
    POINT19UNITS=CF
    POINT19LOW=0
    POINT19HIGH=0
    POINT19CONSOLE=NO
    POINT20NAME=Gas Meter rate
    POINT20UNITS=CFm
    POINT20LOW=0
    POINT20HIGH=0
    POINT20CONSOLE=NO
    POINT21NAME=Gas Meter rate (instantaneous)
    POINT21UNITS=CFm
    POINT21LOW=0
    POINT21HIGH=0
    POINT21CONSOLE=NO
    POINT22NAME=Gas Meter rate min
    POINT22UNITS=CFm
    POINT22LOW=0
    POINT22HIGH=0
    POINT22CONSOLE=NO
    POINT23NAME=Gas Meter rate max
    POINT23UNITS=CFm
    POINT23LOW=0
    POINT23HIGH=0
    POINT23CONSOLE=NO
    POINT24NAME=-
    POINT24UNITS=
    POINT24LOW=0
    POINT24HIGH=0
    POINT24CONSOLE=NO
    POINT25NAME=-
    POINT25UNITS=
    POINT25LOW=0
    POINT25HIGH=0
    POINT25CONSOLE=NO
    POINT26NAME=-
    POINT26UNITS=
    POINT26LOW=0
    POINT26HIGH=0
    POINT26CONSOLE=NO
    POINT27NAME=-
    POINT27UNITS=
    POINT27LOW=0
    POINT27HIGH=0
    POINT27CONSOLE=NO
  
  DEV_CONFIG

  
  # First we receive a CONFIGFILEMANIFEST webhook asking for the config files we want
  body = create_request(
    "CONFIGFILEUPLOAD",
    "Temp Inputs / Branch Circuits",
    "2",
    "9a6d278642b64db73c754271de733758",
    "2022-09-12 21:25:55",
    "CONFIGFILE",
    "modbus/mb-001.ini",
    dev_config
  )

  body = body.gsub("\n", "\r\n")
  resp = exec(:request, "POST", headers, body).get


  dev_log = <<-DEV_LOG
    time(utc),error,low alarm,high alarm,'ION6200 (KWh)','ION6200 demand (kW)','ION6200 rate (instantaneous) (kW)','ION6200 rate min (kW)','ION6200 rate max (kW)','ION6200Reactive (KVARh)','ION6200Reactive demand (kVAR)','ION6200Reactive rate (instantan (kVAR)','ION6200Reactive rate min (kVAR)','ION6200Reactive rate max (kVAR)','Apparent Power (demand) (KVA)','Apparent Power (instantaneous) (KVA)','Power Factor (demand)','Power Factor (instantaneous)','Water Meter (Gallons)','Water Meter rate (Gpm)','Water Meter rate (instantaneous (Gpm)','Water Meter rate min (Gpm)','Water Meter rate max (Gpm)','Gas Meter (CF)','Gas Meter rate (CFm)','Gas Meter rate (instantaneous) (CFm)','Gas Meter rate min (CFm)','Gas Meter rate max (CFm)','-','-','-','-'
    '2004-05-12 15:45:00',0,0,0,141713,,123.288,122.449,123.288,27841,,24.194,24.129,24.194,,125.639,,0.981,0,,,,,0,,,,,,,,
    '2004-05-12 16:00:00',0,0,0,141743,120,123.288,121.622,124.138,27847,24,24.194,24.161,24.194,122.376,125.639,0.981,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 16:15:00',0,0,0,141774,124,123.288,122.449,124.138,27853,24,24.194,24.161,24.194,126.301,125.639,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 16:30:00',0,0,0,141805,124,123.288,121.622,123.288,27859,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 16:45:00',0,0,0,141836,124,123.288,122.449,123.288,27865,24,24.194,24.161,24.194,126.301,125.639,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 17:00:00',0,0,0,141867,124,123.288,122.449,123.288,27871,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 17:15:00',0,0,0,141897,120,122.449,122.449,123.288,27877,24,24.161,24.161,24.194,122.376,124.81,0.981,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 17:30:00',0,0,0,141928,124,123.288,122.449,123.288,27883,24,24.194,24.129,24.194,126.301,125.639,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 17:45:00',0,0,0,141959,124,123.288,121.622,123.288,27889,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 18:00:00',0,0,0,141990,124,123.288,121.622,123.288,27895,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 18:15:00',0,0,0,142020,120,123.288,122.449,123.288,27901,24,24.194,24.129,24.194,122.376,125.639,0.981,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 18:30:00',0,0,0,142051,124,122.449,122.449,123.288,27907,24,24.161,24.129,24.194,126.301,124.81,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 18:45:00',0,0,0,142082,124,122.449,121.622,123.288,27913,24,24.161,24.161,24.194,126.301,124.81,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 19:00:00',0,0,0,142113,124,123.288,122.449,123.288,27919,24,24.194,24.129,24.194,126.301,125.639,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 19:15:00',0,0,0,142144,124,123.288,121.622,123.288,27925,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 19:30:00',0,0,0,142174,120,122.449,122.449,123.288,27932,28,24.129,24.129,24.194,123.223,124.804,0.974,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 19:45:00',0,0,0,142205,124,122.449,122.449,123.288,27938,24,24.161,24.161,24.194,126.301,124.81,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 20:00:00',0,0,0,142236,124,123.288,121.622,123.288,27944,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 20:15:00',0,0,0,142267,124,123.288,122.449,123.288,27950,24,24.161,24.161,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 20:30:00',0,0,0,142297,120,123.288,122.449,123.288,27956,24,24.161,24.161,24.161,122.376,125.633,0.981,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 20:45:00',0,0,0,142328,124,123.288,122.449,123.288,27962,24,24.129,24.129,24.194,126.301,125.627,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 21:00:00',0,0,0,142359,124,122.449,122.449,123.288,27968,24,24.194,24.161,24.194,126.301,124.816,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 21:15:00',0,0,0,142390,124,123.288,121.622,123.288,27974,24,24.194,24.129,24.194,126.301,125.639,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 21:30:00',0,0,0,142421,124,123.288,121.622,123.288,27980,24,24.161,24.129,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 21:45:00',0,0,0,142451,120,123.288,122.449,123.288,27986,24,24.194,24.161,24.194,122.376,125.639,0.981,0.981,0,0,,,,0,0,,,,,,,
    '2004-05-12 22:00:00',0,0,0,142482,124,123.288,121.622,123.288,27992,24,24.161,24.129,24.194,126.301,125.633,0.982,0.981,0,0,,,,0,0,,,,,,,
  DEV_LOG

  # Now, finally, send an actual log file 
  body = create_request(
    "LOGFILEUPLOAD",
    "Temp Inputs / Branch Circuits",
    "2",
    "9a6d278642b64db73c754271de733758",
    "2022-09-12 21:25:55",
    "LOGFILE",
    "tmp_name",
    dev_log
  )
  body = body.gsub("\n", "\r\n")
  resp = exec(:request, "POST", headers, body).get

end


# Some of these fields may not be present in every request but
# having them there doesn't hurt anything so why bother removing them
def create_request(mode : String, device_name : String, modbus_device : String, md5 : String, file_time : String, file_descriptor : String, file_name : String, file : String)
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