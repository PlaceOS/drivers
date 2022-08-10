require "placeos-driver/spec"

DriverSpecs.mock_driver "Ict::Wx" do
  resp = exec(:get_session_key)
  resp = exec(:get_api_key)
  # # expect_http_request do |_request, response|
  # #   response.status_code = 200
  # #   response.output.puts("TEST")
  # # end
  # backend = ::Log::IOBackend.new(STDOUT)
  # ::Log.setup { |c| c.bind("*", :info, backend) }
  # # Log.info {resp}
  # # Log.info{resp.inspect}
  # # expect_http_request do |_request, response|
  # #   response.status_code = 200
  # #   response << %([{"Building":"SYDNEY","Level":"0","Online":13},{"Building":"SYDNEY","Level":"2","Online":14}])
  # # end
  # # res = JSON.parse(resp.get)
  # Log.info { resp.get }
  # resp.get.should eq("TEST")
  # resp.get.should be < 1000000
end
