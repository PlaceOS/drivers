DriverSpecs.mock_driver "Vergesense::VergesenseAPI" do
  expect_http_request do |request, response|
    case request.path
    when "/buildings"
      response.status_code = 200
      response << %([{
      "name": "HQ 1",
      "building_ref_id": "HQ1",
      "address": null
    }])
    end
  end

  puts "SENT BUILDINGS"

  expect_http_request do |request, response|
    case request.path
    when "/buildings/HQ1"
      response.status_code = 200
      response << %({
  "building_ref_id": "HQ1",
  "capacity": 84,
  "minimum_social_distance": 2.0,
  "floors": [
    {
      "name": "Floor 1",
      "floor_ref_id": "FL1",
      "capacity": 84,
      "max_capacity": 60,
      "spaces": [
        {
          "name": "Conference Room 0721",
          "space_ref_id": "CR_0721",
          "space_type": "conference_room",
          "capacity": 4,
          "max_capacity": 3,
          "sensors": [
            {
              "id": "L_000018",
              "partitions": [
                {
                  "id": "L_000018/321"
                }
              ]
            }
          ],
          "geometry": {
            "type": "Polygon",
            "coordinates": [
              [
                [
                  93.850772,
                  44.676952
                ],
                [
                  93.850739,
                  44.676929
                ],
                [
                  93.850718,
                  44.67695
                ],
                [
                  93.850751,
                  44.676973
                ],
                [
                  93.850772,
                  44.676952
                ],
                [
                  93.850772,
                  44.676952
                ]
              ]
            ]
          }
        }
      ]
    }
  ]
})
    end
  end

  puts "SENT FLOORS"

  expect_http_request do |request, response|
    case request.path
    when "/spaces"
      response.status_code = 200
      response << %([
    {
        "building_ref_id": "HQ1",
        "floor_ref_id": "FL1",
        "space_ref_id": "CR_0721",
        "name": "Conference Room 0721",
        "space_type": "conference_room",
        "last_reports": [
            {
                "id": "W91-IGI",
                "person_count": 2,
                "signs_of_life": null,
                "motion_detected": null,
                "timestamp": "2019-07-29T18:42:19Z"
            }
        ],
        "people": {
            "count": 2,
            "distances": {
                "units": "meters",
                "values": [2.42]
            }
        }
    }
])
    end
  end

  puts "SENT SPACES"

  status["HQ1-FL1"].should eq({
    "floor_ref_id" => "FL1",
    "name"         => "Floor 1",
    "capacity"     => 84,
    "max_capacity" => 60,
    "spaces"       => [
      {
        "building_ref_id" => "HQ1",
        "floor_ref_id"    => "FL1",
        "space_ref_id"    => "CR_0721",
        "space_type"      => "conference_room",
        "name"            => "Conference Room 0721",
        "capacity"        => 4,
        "max_capacity"    => 3,
        "geometry"        => {"type" => "Polygon", "coordinates" => [[[93.850772, 44.676952], [93.850739, 44.676929], [93.850718, 44.67695], [93.850751, 44.676973], [93.850772, 44.676952], [93.850772, 44.676952]]]},
        "people"          => {"count" => 2},
      },
    ],
  })

  # Testing webhook save
  webhook_space_report_event = %({
    "building_ref_id": "HQ1",
    "floor_ref_id": "FL1",
    "space_ref_id": "CR_0721",
    "sensor_ids": ["VS0-123", "VS1-321"],
    "person_count": 21,
    "signs_of_life": null,
    "motion_detected": true,
    "event_type": "space_report",
    "timestamp": "2019-08-21T21:10:25Z",
    "people": {
      "count": 21,
      "coordinates": [
        [
          [
            2.2673,
            4.3891
          ],
          [
            6.2573,
            1.5303
          ]
        ]
      ],
      "distances": {
        "units": "meters",
        "values": [1.5]
      }
    }
  })

  exec(:space_report_api, method: "update", headers: {"test" => ["test"]}, body: webhook_space_report_event).get

  status["HQ1-FL1"].should eq({
    "floor_ref_id" => "FL1",
    "name"         => "Floor 1",
    "capacity"     => 84,
    "max_capacity" => 60,
    "spaces"       => [
      {
        "building_ref_id" => "HQ1",
        "floor_ref_id"    => "FL1",
        "space_ref_id"    => "CR_0721",
        "space_type"      => "conference_room",
        "name"            => "Conference Room 0721",
        "capacity"        => 4,
        "max_capacity"    => 3,
        "geometry"        => {"type" => "Polygon", "coordinates" => [[[93.850772, 44.676952], [93.850739, 44.676929], [93.850718, 44.67695], [93.850751, 44.676973], [93.850772, 44.676952], [93.850772, 44.676952]]]},
        "people"          => {
          "count"       => 21,
          "coordinates" => [[[2.2673, 4.3891], [6.2573, 1.5303]]],
        },
        "timestamp"       => "2019-08-21T21:10:25Z",
        "motion_detected" => true,
      },
    ],
  })
end
