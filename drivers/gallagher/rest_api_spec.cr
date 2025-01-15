require "./rest_api_models"
require "placeos-driver/spec"

DriverSpecs.mock_driver "Gallagher::RestAPI" do
  Log.debug { "expecting API paths request..." }
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts %({
      "version": "8.50.1414.0",
      "features": {
        "doors": {
          "doors": {
            "href": "https://localhost:8904/api/doors"
          }
        },
        "cardholders": {
          "cardholders": {
            "href": "https://localhost:8904/api/cardholders"
          }
        },
        "accessGroups": {
          "accessGroups": {
            "href": "https://localhost:8904/api/access_groups"
          }
        },
        "events": {
          "events": {
            "href": "https://localhost:8904/api/events"
          }
        },
        "cardTypes": {
          "assign": {
            "href": "https://localhost:8904/api/card_types"
          }
        },
        "personalDataFields": {
          "personalDataFields": {
            "href": "https://localhost:8904/api/personal_data_fields"
          }
        }
      }
    })
  end
  Log.debug { "API paths received" }

  Log.debug { "creating a cardholder..." }
  exec(:create_cardholder,
    first_name: "Steve",
    last_name: "Takach",
    cards: [{number: "12345"}],
    pdfs: {
      "email" => "test@email.com",
    }
  )
  data = ""
  expect_http_request do |request, response|
    response.status_code = 201
    response.headers["Location"] = "https://localhost:8904/api/cardholders/4567"
    data = request.body.not_nil!.gets_to_end
  end
  Log.debug { "cardholder created" }

  Log.debug { "expecting cardholder request..." }
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output.puts({
      first_name: "Steve",
      last_name:  "Takach",
      cards:      [{number: "12345"}],
      pdfs:       {
        "email" => "test@email.com",
      },
    }.to_json)
  end
  Log.debug { "cardholder data sent" }
end
