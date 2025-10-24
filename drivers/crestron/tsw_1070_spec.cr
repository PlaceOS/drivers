require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Tsw1070" do
  # Set up ALL expected HTTP requests FIRST

  # Expect authentication request
  expect_http_request do |request, response|
    data = request.body.try(&.gets_to_end)
    if data == "login=admin&passwd=admin"
      response.status_code = 200
      response.headers.add("Set-Cookie", [
        "userstr=61766974735f61646d696e;Path=/;Secure;HttpOnly;",
        "userid=7e0d210a66fc97b85347d7affc363b41672e9cad2ba8b8fa65019ea24cf2d7b909cd6d25985cc7e9471c03c83409c58c;Path=/;Secure;HttpOnly;",
        "iv=762701d96ba69f0800cd5b439fcc7020;Path=/;Secure;HttpOnly;",
        "tag=00000000000000000000000000000000;Path=/;Secure;HttpOnly;",
        "AuthByPasswd=crypt%3Ac17e34deffafa812f2a9f6570cee4d9234a24e1352379c7253e7907cabc7229a;Path=/;Secure;HttpOnly;",
        "TRACKID=6a8ac5cc159f81f90923406823bcde63890c330b6a99db6ba945237de1b59bfc;Path=/;Secure;HttpOnly;",
      ])
      response.headers["CREST-XSRF-TOKEN"] = "1234"
    else
      response.status_code = 401
      response << "bad password"
    end
  end

  # Expect the device poll request
  expect_http_request do |request, response|
    if request.path == "/Device"
      response.status_code = 200
      response << %({
        "Device": {
          "DeviceInfo": {
            "Model": "TSW-1070",
            "Category": "TouchPanel",
            "Manufacturer": "Crestron",
            "ModelId": "0x79FE",
            "DeviceId": "@E-00107fda645f",
            "SerialNumber": "1948JBH01948",
            "Name": "TSW-1070-001",
            "DeviceVersion": "3.002.0034",
            "PufVersion": "3.002.0034.001",
            "BuildDate": "Tue Jul  1 15:31:42 EDT 2025  (574110)",
            "Devicekey": "No SystemKey Server",
            "MacAddress": "00:10:7F:DA:64:5F",
            "RebootReason": "unknown",
            "Version": "2.3.1"
          }
        }
      })
    else
      response.status_code = 404
      response << "not found"
    end
  end

  # NOW trigger the driver methods
  exec :authenticate
  exec :poll_device_state

  sleep 0.5.seconds

  # Verify status was updated correctly
  status[:model].should eq("TSW-1070")
  status[:category].should eq("TouchPanel")
  status[:manufacturer].should eq("Crestron")
  status[:serial_number].should eq("1948JBH01948")
  status[:device_version].should eq("3.002.0034")
  status[:puf_version].should eq("3.002.0034.001")
  status[:mac_address].should eq("00:10:7F:DA:64:5F")
  status[:api_version].should eq("2.3.1")
end
