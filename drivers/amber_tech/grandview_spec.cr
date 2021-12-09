require "placeos-driver/spec"

DriverSpecs.mock_driver "AmberTech::Grandview" do
  retval = exec(:status)

  expect_http_request do |request, response|
    raise "unexpected path #{request.path} for info" unless request.path == "/GetDevInfoList.js"
    response.status_code = 200
    response << %({
      "currentIp":"10.142.196.27",
      "devInfo":[
        {
          "ver":"1.0",
          "id":"1015095851",
          "ip":"10.142.196.27",
          "sub":"255.255.255.128",
          "gw":"10.142.196.1",
          "name":"CII_Scrn",
          "pass":"admin",
          "pass2":"config",
          "status":"Closed"
        }
      ]
    })
  end

  retval.get
  status[:status].should eq "closed"

  retval = exec(:move, "down")
  expect_http_request do |request, response|
    raise "unexpected path #{request.path} for move down" unless request.path == "/Open.js"
    response.status_code = 200
    response << %({"status":"Opening"})
  end
  retval.get.should eq "opening"
  status[:status].should eq "opening"
end
