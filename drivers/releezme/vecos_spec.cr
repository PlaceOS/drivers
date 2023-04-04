require "placeos-driver/spec"

DriverSpecs.mock_driver "GoBright::API" do
  resp = exec :locations

  expect_http_request do |request, response|
    case request.path
    when "/connect/token"
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
    when "/api/locations?pageSize=200&pageNumber=1"
      response.status_code = 200
      response << %({
        "Locations": [{
          "Id": "loc-1234",
          "Name": "Level 2"
        }],
        "Paging": {
          "FirstItemOnPage": 1,
          "HasNextPage": true,
          "HasPreviousPage": false,
          "IsFirstPage": true,
          "IsLastPage": false,
          "LastItemOnPage": 1,
          "PageCount": 2,
          "PageNumber": 1,
          "PageSize": 2,
          "TotalItemCount": 2
        }
      })
    else
      response.status_code = 500
      response << "expected locations request"
    end
  end

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/locations?pageSize=200&pageNumber=2"
      response.status_code = 200
      response << %({
        "Locations": [{
          "Id": "loc-5678",
          "Name": "Level 3"
        }],
        "Paging": {
          "FirstItemOnPage": 1,
          "HasNextPage": false,
          "HasPreviousPage": true,
          "IsFirstPage": false,
          "IsLastPage": true,
          "LastItemOnPage": 1,
          "PageCount": 2,
          "PageNumber": 2,
          "PageSize": 2,
          "TotalItemCount": 2
        }
      })
    else
      response.status_code = 500
      response << "expected locations request"
    end
  end

  resp.get.should eq [
    {"Id" => "loc-1234", "Name" => "Level 2"},
    {"Id" => "loc-5678", "Name" => "Level 3"}
  ]
end
