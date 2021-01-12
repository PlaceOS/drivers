DriverSpecs.mock_driver "Xovis::SensorAPI" do
  # Send the request
  retval = exec(:get_token)

  # We should request a new token from Floorsense
  expect_http_request do |request, response|
    if io = request.body
      data = io.gets_to_end

      # The request is param encoded
      if data == "username=srvc_acct&password=password%21"
        response.status_code = 200
        response.output.puts %({"type":"response","result":true,"message":"Authentication successful","info":{"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzbWFydGFsb2NrLWQ1MGJjZC5sb2NhbGRvbWFpbiIsInN1YiI6ImFjYSIsImF1ZCI6ImFwaSIsImV4cCI6MTU3MjMwODMzMiwiaWF0IjoxNTcyMzA0NzMyfQ.KMlzvjYPFw9e5d5LQjb1BF5R1Je9KkgoigkNOUZnR4U","sessionid":"ace555fe-4914-4203-b0a3-a1a6f532fef7"}})
      else
        response.status_code = 401
        response.output.puts %({"type":"response","result":false,"message":"Authentication failed","code":17})
      end
    else
      raise "expected request to include username and password"
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzbWFydGFsb2NrLWQ1MGJjZC5sb2NhbGRvbWFpbiIsInN1YiI6ImFjYSIsImF1ZCI6ImFwaSIsImV4cCI6MTU3MjMwODMzMiwiaWF0IjoxNTcyMzA0NzMyfQ.KMlzvjYPFw9e5d5LQjb1BF5R1Je9KkgoigkNOUZnR4U")
end
