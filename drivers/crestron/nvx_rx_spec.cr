require "placeos-driver/spec"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxRx" do
  # Connected callback makes some queries
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Receiver"}}})

  should_send "/Device/XioSubscription/Subscriptions"

  # we call this manually as the driver isn't loaded in websocket mode
  exec :authenticate

  # We expect the first thing it to do is authenticate
  auth = URI::Params.build { |form|
    form.add("login", "admin")
    form.add("passwd", "admin")
  }

  expect_http_request do |request, response|
    io = request.body
    if io
      request_body = io.gets_to_end
      if request_body == auth
        response.status_code = 200
        response.headers["CREST-XSRF-TOKEN"] = "1234"
        cookies = response.cookies
        cookies["AuthByPasswd"] = "true"
        cookies["iv"] = "true"
        cookies["tag"] = "true"
        cookies["userid"] = "admin"
        cookies["userstr"] = "admin"
      else
        response.status_code = 401
      end
    else
      raise "expected request to include login form #{request.inspect}"
    end
  end
end
