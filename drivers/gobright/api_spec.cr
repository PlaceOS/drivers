require "placeos-driver/spec"

DriverSpecs.mock_driver "GoBright::API" do
  resp = exec :locations

  expect_http_request do |request, response|
    case request.path
    when "/token"
      response.status_code = 200
      response << %({
        "access_token": "1234",
        "expires_in": 300
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/v2.0/locations?pagingTake=100"
      response.status_code = 200
      response << %({
        "data": [{
          "id": "loc-1234",
          "name": "Level 2"
        }],
        "paging": {
          "continuationToken": "continue123"
        }
      })
    else
      response.status_code = 500
      response << "expected locations request"
    end
  end

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/v2.0/locations?pagingTake=100&continuationToken=continue123"
      response.status_code = 200
      response << %({
        "data": [{
          "id": "loc-5678",
          "name": "Level 3"
        }]
      })
    else
      response.status_code = 500
      response << "expected second locations request"
    end
  end

  resp.get.should eq([
    {
      "id"   => "loc-1234",
      "name" => "Level 2",
    },
    {
      "id"   => "loc-5678",
      "name" => "Level 3",
    },
  ])
end
