require "./models/**"
require "placeos-driver/spec"

DriverSpecs.mock_driver "TwentyFiveLivePro::API" do
  # Reservations

  list_reservations = exec(:list_reservations, 88, "2023-06-26T00:00:00", "2023-06-27T00:00:00")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/reservations.json?space_id=88&start_dt=2023-06-26T00:00:00&end_dt=2023-06-27T00:00:00"
      response.status_code = 200
      response << %({
        "reservations": {
          "engine": "accl",
          "reservation": [
            {
              "post_event_dt": "2023-06-26T11:30:00-04:00",
              "registration_url": "",
              "event_end_dt": "2023-06-26T11:30:00-04:00",
              "profile_description": "",
              "profile_name": "M 1000-1130 05/08",
              "reservation_comment_id": "",
              "expected_count": 150,
              "reservation_state_name": "Standard",
              "last_mod_dt": "2023-01-12T15:47:37-05:00",
              "space_reservation": {
                "default_layout_capacity": 168,
                "shared": "F",
                "layout_id": 2,
                "layout_name": "As Is",
                "space_instructions": "",
                "space_name": "CLH A",
                "space_instruction_id": "",
                "selected_layout_capacity": 168,
                "actual_count": "",
                "space_id": 88,
                "formal_name": "Redacted Lecture Hall A - Lecture Hall"
              },
              "event_title": "SC MATH 1507  3.00 A LECT 01 EN (Term SUSC)",
              "reservation_state": 1,
              "event_locator": "2023-AAKSTR",
              "organization_name": "SC MATH",
              "event_type_class": "",
              "event_type_name": "LECT",
              "reservation_start_dt": "2023-06-26T10:00:00-04:00",
              "reservation_comments": "",
              "reservation_id": 2793064,
              "pre_event_dt": "2023-06-26T10:00:00-04:00",
              "event_id": 81053,
              "profile_id": 100682,
              "organization_id": 473,
              "reservation_end_dt": "2023-06-26T11:30:00-04:00",
              "registered_count": 102,
              "last_mod_user": "aaross",
              "event_name": "SC MATH 1507  3.00 A MMP 2022-3",
              "event_start_dt": "2023-06-26T10:00:00-04:00",
              "registration_label": ""
            },
            {
              "post_event_dt": "2023-06-26T15:00:00-04:00",
              "registration_url": "",
              "event_end_dt": "2023-06-26T15:00:00-04:00",
              "profile_description": "",
              "profile_name": "M 1300-1500 05/08",
              "reservation_comment_id": "",
              "expected_count": 150,
              "reservation_state_name": "Standard",
              "last_mod_dt": "2023-01-12T15:47:37-05:00",
              "space_reservation": {
                "default_layout_capacity": 168,
                "shared": "F",
                "layout_id": 2,
                "layout_name": "As Is",
                "space_instructions": "",
                "space_name": "CLH A",
                "space_instruction_id": "",
                "selected_layout_capacity": 168,
                "actual_count": 150,
                "space_id": 88,
                "formal_name": "Redacted Lecture Hall A - Lecture Hall"
              },
              "event_title": "LE EECS 2031  3.00 A LECT 01 EN (Term SULE)",
              "reservation_state": 1,
              "event_locator": "2023-AAKSZL",
              "organization_name": "LE EECS",
              "event_type_class": "",
              "event_type_name": "LECT",
              "reservation_start_dt": "2023-06-26T13:00:00-04:00",
              "reservation_comments": "",
              "reservation_id": 2794453,
              "pre_event_dt": "2023-06-26T13:00:00-04:00",
              "event_id": 81132,
              "profile_id": 100778,
              "organization_id": 367,
              "reservation_end_dt": "2023-06-26T15:00:00-04:00",
              "registered_count": 142,
              "last_mod_user": "aaross",
              "event_name": "LE EECS 2031  3.00 A 2022-3",
              "event_start_dt": "2023-06-26T13:00:00-04:00",
              "registration_label": ""
            },
            {
              "post_event_dt": "2023-06-26T21:00:00-04:00",
              "registration_url": "",
              "event_end_dt": "2023-06-26T21:00:00-04:00",
              "profile_description": "",
              "profile_name": "M 1800-2100 05/08",
              "reservation_comment_id": "",
              "expected_count": 150,
              "reservation_state_name": "Standard",
              "last_mod_dt": "2023-01-12T15:47:37-05:00",
              "space_reservation": {
                "default_layout_capacity": 168,
                "shared": "F",
                "layout_id": 2,
                "layout_name": "As Is",
                "space_instructions": "",
                "space_name": "CLH A",
                "space_instruction_id": "",
                "selected_layout_capacity": 168,
                "actual_count": "",
                "space_id": 88,
                "formal_name": "Redacted Lecture Hall A - Lecture Hall"
              },
              "event_title": "SC MATH 1510  6.00 A LECT 01 EN (Term SUSC)",
              "reservation_state": 1,
              "event_locator": "2023-AAKSTS",
              "organization_name": "SC MATH",
              "event_type_class": "",
              "event_type_name": "LECT",
              "reservation_start_dt": "2023-06-26T18:00:00-04:00",
              "reservation_comments": "",
              "reservation_id": 2793093,
              "pre_event_dt": "2023-06-26T18:00:00-04:00",
              "event_id": 81054,
              "profile_id": 100684,
              "organization_id": 473,
              "reservation_end_dt": "2023-06-26T21:00:00-04:00",
              "registered_count": 58,
              "last_mod_user": "aaross",
              "event_name": "SC MATH 1510  6.00 A MMP 2022-3",
              "event_start_dt": "2023-06-26T18:00:00-04:00",
              "registration_label": ""
            }
          ],
          "pubdate": "2023-07-10T12:21:05-04:00"
        }
      })
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  reservations = Array(TwentyFiveLivePro::Models::Reservation).from_json(list_reservations.get.not_nil!.to_json)
  reservations.size should eq 3
  reservations.first.reservation_id.should eq 2793064


  # Spaces

  get_space_details = exec(:get_space_details, 1, ["all"], ["all"])

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/space/1/detail.json?include=all&expand=all"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 365785,
          "updated": "2023-04-05T00:37:53-07:00",
          "data": {
            "items": [
              {
                "kind": "space",
                "id": 1,
                "etag": "00000029",
                "spaceName": "0104-232",
                "spaceFormalName": "Cox Science Center, 232",
                "maxCapacity": 24,
                "updated": "2013-08-01T08:17:01-07:00",
                "layouts": [],
                "features": [],
                "categories": [],
                "attributes": [
                  {
                    "attributeId": -38,
                    "value": "Wet Lab - Research"
                  },
                  {
                    "attributeId": -37,
                    "value": "OPEN"
                  },
                  {
                    "attributeId": -36,
                    "value": "G"
                  },
                  {
                    "attributeId": -33,
                    "value": "Second Floor"
                  },
                  {
                    "attributeId": -32
                  },
                  {
                    "attributeId": -31,
                    "value": "2008-05-30"
                  },
                  {
                    "attributeId": -30,
                    "value": "T"
                  },
                  {
                    "attributeId": -12,
                    "value": "1350"
                  },
                  {
                    "attributeId": -10,
                    "value": "2"
                  },
                  {
                    "attributeId": -9,
                    "value": "250-04"
                  },
                  {
                    "attributeId": -7
                  },
                  {
                    "attributeId": -6,
                    "value": "Cox Science Center"
                  }
                ],
                "roles": []
              }
            ]
          },
          "expandedInfo": {
            "attributes": [
              {
                "attributeId": -30,
                "attributeName": "1",
                "dataType": "B"
              },
              {
                "attributeId": -31,
                "attributeName": "1",
                "dataType": "D"
              },
              {
                "attributeId": -32,
                "attributeName": "1",
                "dataType": "D"
              },
              {
                "attributeId": -33,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -38,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -36,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -37,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -12,
                "attributeName": "1",
                "dataType": "N"
              },
              {
                "attributeId": -6,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -10,
                "attributeName": "1",
                "dataType": "S"
              },
              {
                "attributeId": -7,
                "attributeName": "1",
                "dataType": "2"
              },
              {
                "attributeId": -9,
                "attributeName": "1",
                "dataType": "S"
              }
            ],
            "roles": [],
            "contacts": []
          }
        }
      })
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  space_detail = TwentyFiveLivePro::Models::SpaceDetail.from_json(get_space_details.get.not_nil!.to_json)
  space_detail.content.data.items.first.id.should eq 1

  list_spaces = exec(:list_spaces, 1, 10, nil)

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/space/list.json?page=1&itemsPerPage=10"
      response.status_code = 200
      response << %({
      "content": {
        "requestId": 365784,
        "updated": "2023-04-04T22:19:51-07:00",
        "data": {
          "paginateKey": 16414,
          "pageIndex": 1,
          "totalPages": 1,
          "totalItems": 10,
          "currentItemCount": 10,
          "itemsPerPage": 10,
          "pagingLinkTemplate": "https://webservices.collegenet.com/r25ws/wrd/partners/run/external/space/list.json?current_cont_id=754&paginate=16414&page={index}&order=asc",
          "items": [
            {
              "kind": "space",
              "id": 37932,
              "etag": "00000029",
              "spaceName": "0104-232",
              "spaceFormalName": "Cox Science Center, 232",
              "maxCapacity": 24,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 37929,
              "etag": "00000027",
              "spaceName": "0509-111",
              "spaceFormalName": "Handleman Building, 111",
              "maxCapacity": 10,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 37671,
              "etag": "00000021",
              "spaceName": "1_R1",
              "spaceFormalName": "First Floor Conference Room",
              "maxCapacity": 12,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 13296,
              "etag": "00000024",
              "spaceName": "100*133",
              "spaceFormalName": "Classroom - M",
              "maxCapacity": 42,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 13301,
              "etag": "00000024",
              "spaceName": "100*142",
              "spaceFormalName": "Classroom - M",
              "maxCapacity": 49,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 40771,
              "etag": "00000021",
              "spaceName": "1028 DANA",
              "maxCapacity": 30,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 40759,
              "etag": "00000021",
              "spaceName": "1040 DANA",
              "maxCapacity": 30,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 40779,
              "etag": "00000021",
              "spaceName": "1045 GGBL",
              "maxCapacity": 30,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 40793,
              "etag": "00000021",
              "spaceName": "1121 LBME",
              "maxCapacity": 30,
              "canRequest": true
            },
            {
              "kind": "space",
              "id": 40747,
              "etag": "00000021",
              "spaceName": "130 TAP",
              "maxCapacity": 30,
              "canRequest": true
            }
          ]
        }
      }
    })
    else
      response.status_code = 500
      response << "expected list spaces request"
    end
  end

  spaces = Array(TwentyFiveLivePro::Models::Space).from_json(list_spaces.get.not_nil!.to_json)
  spaces.size.should eq 10

  get_availability = exec(:availability, 1, "2023-06-04T14:30:00-07:00", "2023-06-04T15:30:00-07:00", ["all"], ["all"])

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/spaceAvailability.json?include=all&expand=all"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": "365796",
          "updated": "2023-04-05T01:32:44-07:00",
          "data": {
            "spaces": [
              {
                "spaceId": 1,
                "dates": [
                  {
                    "startDt": "2023-06-04T14:30:00-07:00",
                    "endDt": "2023-06-04T15:30:00-07:00"
                  }
                ],
                "available": false,
                "conflictType": 3
              }
            ]
          },
          "expandedInfo": {
            "conflictTypes": [
              {
                "conflictTypeId": 1,
                "conflictTypeName": "pendRes",
                "conflictTypeDescription": "Conflicts with a pending space reservation for this space."
              },
              {
                "conflictTypeId": 2,
                "conflictTypeName": "res",
                "conflictTypeDescription": "Conflicts with a space reservation for this space."
              },
              {
                "conflictTypeId": 3,
                "conflictTypeName": "hour",
                "conflictTypeDescription": "Conflicts with the Open/Close hour setting for this space."
              },
              {
                "conflictTypeId": 4,
                "conflictTypeName": "blackout",
                "conflictTypeDescription": "Conflicts with a blackout for this space."
              }
            ]
          }
        }
      })
    else
      response.status_code = 500
      response << "expected list spaces request"
    end
  end

  availability = TwentyFiveLivePro::Models::Availability.from_json(get_availability.get.not_nil!.to_json)
  availability.content.data.spaces.first.space_id.should eq 1

  # Resources

  get_resource_details = exec(:get_resource_details, 1, ["all"], ["all"])

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/resource/1/detail.json?include=all&expand=all"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 365793,
          "updated": "2023-04-05T01:03:14-07:00",
          "data": {
            "items": [
              {
                "kind": "resource",
                "id": 1,
                "etag": "00000021",
                "resourceName": "1",
                "updated": "2001-11-19T11:41:39-08:00",
                "categories": [
                  {
                    "categoryId": 935
                  }
                ],
                "attributes": [],
                "stock": [
                  {
                    "versionNumber": 2,
                    "startDate": "2001-11-19T00:00:00",
                    "endDate": "2100-12-31T00:00:00",
                    "stockLevel": 2
                  }
                ]
              }
            ]
          },
          "expandedInfo": [
            {
              "categories": [
                {
                  "categoryId": 935,
                  "categoryName": "1"
                }
              ]
            }
          ]
        }
      })
    else
      response.status_code = 500
      response << "expected get resource details request"
    end
  end

  resource_detail = TwentyFiveLivePro::Models::ResourceDetail.from_json(get_resource_details.get.not_nil!.to_json)
  resource_detail.content.data.items.first.id.should eq 1

  list_resources = exec(:list_resources, 1, 10, nil)

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/resource/list.json?page=1&itemsPerPage=10"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 365792,
          "updated": "2023-04-05T01:01:36-07:00",
          "data": {
            "paginateKey": 16419,
            "pageIndex": 1,
            "totalPages": 1,
            "totalItems": 67,
            "currentItemCount": 10,
            "itemsPerPage": 10,
            "pagingLinkTemplate": "https://webservices.collegenet.com/r25ws/wrd/partners/run/external/resource/list.json?current_cont_id=754&paginate=16419&page={index}&order=asc",
            "items": [
              {
                "kind": "resource",
                "id": 29,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 87,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 12,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 62,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 69,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 10,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 57,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 54,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 4,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              },
              {
                "kind": "resource",
                "id": 75,
                "etag": "00000021",
                "resourceName": "1",
                "canRequest": true
              }
            ]
          }
        }
      })
    else
      response.status_code = 500
      response << "expected list resources request"
    end
  end

  resources = Array(TwentyFiveLivePro::Models::Resource).from_json(list_resources.get.not_nil!.to_json)
  resources.size.should eq 10

  # Organizations

  get_organization_details = exec(:get_organization_details, 1, ["all"], ["all"])

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/organization/1/detail.json?include=all&expand=all"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 1,
          "updated": "2023-04-05T01:00:08-07:00",
          "data": {
            "items": [
              {
                "kind": "organization",
                "id": 1,
                "etag": "0000003A",
                "organizationName": "1",
                "organizationTitle": "1",
                "updated": "2013-08-01T08:16:20.230-07:00",
                "organizationTypeId": 16,
                "categories": [
                  {
                    "categoryId": 945
                  }
                ],
                "attributes": [
                  {
                    "attributeId": -42,
                    "value": "F"
                  },
                  {
                    "attributeId": -41,
                    "value": "22505-00"
                  }
                ]
              }
            ]
          },
          "expandedInfo": [
            {
              "categories": [
                {
                  "categoryId": 945,
                  "categoryName": "1"
                }
              ],
              "attributes": [
                {
                  "attributeId": -41,
                  "attributeName": "1",
                  "dataType": "S"
                },
                {
                  "attributeId": -42,
                  "attributeName": "1",
                  "dataType": "B"
                }
              ],
              "organization_types": [
                {
                  "organizationTypeId": 16,
                  "orgTypeName": "1",
                  "rateGroupId": 11
                }
              ]
            }
          ]
        }
      })
    else
      response.status_code = 500
      response << "expected get organization details request"
    end
  end

  organization_detail = TwentyFiveLivePro::Models::OrganizationDetail.from_json(get_organization_details.get.not_nil!.to_json)
  organization_detail.content.data.items.first.id.should eq 1

  list_organizations = exec(:list_organizations, 1, 10, nil)

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/organization/list.json?page=1&itemsPerPage=10"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 365790,
          "updated": "2023-04-05T00:57:56-07:00",
          "data": {
            "paginateKey": 16418,
            "pageIndex": 1,
            "totalPages": 1,
            "totalItems": 291,
            "currentItemCount": 10,
            "itemsPerPage": 10,
            "pagingLinkTemplate": "https://webservices.collegenet.com/r25ws/wrd/partners/run/external/organization/list.json?current_cont_id=754&paginate=16418&page={index}&order=asc",
            "items": [
              {
                "kind": "organization",
                "id": 31888,
                "etag": "0000003A",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 16
              },
              {
                "kind": "organization",
                "id": 32247,
                "etag": "00000021",
                "organizationName": "1",
                "organizationTypeId": 27
              },
              {
                "kind": "organization",
                "id": 269,
                "etag": "0000002C",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 23
              },
              {
                "kind": "organization",
                "id": 211,
                "etag": "00000026",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 23
              },
              {
                "kind": "organization",
                "id": 32103,
                "etag": "00000033",
                "organizationName": "1"
              },
              {
                "kind": "organization",
                "id": 32096,
                "etag": "00000033",
                "organizationName": "1"
              },
              {
                "kind": "organization",
                "id": 31383,
                "etag": "00000021",
                "organizationName": "1",
                "organizationTypeId": 27
              },
              {
                "kind": "organization",
                "id": 31951,
                "etag": "00000039",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 16
              },
              {
                "kind": "organization",
                "id": 15988,
                "etag": "00000024",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 27
              },
              {
                "kind": "organization",
                "id": 247,
                "etag": "00000025",
                "organizationName": "1",
                "organizationTitle": "1",
                "organizationTypeId": 16
              }
            ]
          }
        }
      })
    else
      response.status_code = 500
      response << "expected list organizations request"
    end
  end

  organizations = Array(TwentyFiveLivePro::Models::Organization).from_json(list_organizations.get.not_nil!.to_json)
  organizations.size.should eq 10

  # Events

  get_event_details = exec(:get_event_details, 1, ["all"], ["all"])

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/event/1/detail.json?include=all&expand=all"
      response.status_code = 200
      response << %({
        "content": {
          "id": 365795,
          "updated": "2023-04-05T01:08:28-07:00",
          "data": {
            "items": [
              {
                "kind": "event",
                "id": 1,
                "etag": "00000021",
                "name": "cccccccc",
                "title": "RoomView Created Event",
                "eventLocator": "2023-AASXCJ",
                "priority": 0,
                "updated": "2023-04-04T17:17:52-07:00",
                "dates": {
                  "startDate": "2023-04-04T14:30:00-07:00",
                  "endDate": "2023-04-04T15:00:00-07:00"
                },
                "organizations": {},
                "context": {
                  "state": 1,
                  "typeId": 231,
                  "parentId": 63070
                },
                "categories": [],
                "attributes": [],
                "requirements": [],
                "roles": [
                  {
                    "roleId": -2,
                    "contactId": 718
                  }
                ],
                "text": [
                  {}
                ],
                "profiles": [
                  {
                    "profileId": 169006,
                    "name": "Rsrv_169006",
                    "expectedCount": null,
                    "registeredCount": null,
                    "occurrenceDefn": {
                      "recTypeId": 0,
                      "initStartDt": "2023-04-04T14:30:00-07:00",
                      "initEndDt": "2023-04-04T15:00:00-07:00"
                    },
                    "comments": "~tromeo@crestron.com~admin",
                    "reservations": [
                      {
                        "rsrvId": 1031353,
                        "state": 1,
                        "rsrvStartDt": "2023-04-04T14:30:00-07:00",
                        "evStartDt": "2023-04-04T14:30:00-07:00",
                        "evEndDt": "2023-04-04T15:00:00-07:00",
                        "rsrvEndDt": "2023-04-04T15:00:00-07:00",
                        "spaces": [
                          {
                            "reserved": [
                              {
                                "spaceId": 40722,
                                "share": false,
                                "instructions": "[rv]",
                                "rating": 0
                              }
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          },
          "expandedInfo": {
            "organizations": [],
            "roles": [
              {
                "roleId": -2,
                "etag": "00000021",
                "roleName": "Scheduler"
              }
            ],
            "spaces": [
              {
                "spaceId": 40722,
                "etag": "00000021",
                "spaceName": "MSIMS_003",
                "spaceFormalName": "Michael Sims Test Room 003",
                "maxCapacity": 60
              }
            ],
            "resources": [],
            "states": [
              {
                "state": 1,
                "stateName": "Tentative"
              }
            ],
            "eventTypes": [
              {
                "typeId": 231,
                "typeName": "Meeting"
              }
            ],
            "parentNodes": [
              {
                "id": 63070,
                "locator": "2019-AAHVAJ",
                "name": "Standard Events",
                "title": "New Folder 63070",
                "nodeType": "folder",
                "typeName": "Event Folder",
                "startDt": "2019-01-01T00:00:00-08:00",
                "endDt": "2050-12-31T23:59:00-08:00"
              }
            ],
            "contacts": [
              {
                "contactId": 718,
                "etag": "00000021",
                "firstName": null,
                "familyName": "Crestron",
                "email": "rpollard@crestron.com",
                "isFavorite": false
              }
            ]
          }
        }
      })
    else
      response.status_code = 500
      response << "expected get event details request"
    end
  end

  event_detail = TwentyFiveLivePro::Models::EventDetail.from_json(get_event_details.get.not_nil!.to_json)
  event_detail.content.data.items.first.id.should eq 1

  list_events = exec(:list_events, 1, 10, nil)

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/event/list.json?page=1&itemsPerPage=10"
      response.status_code = 200
      response << %({
        "content": {
          "requestId": 365786,
          "updated": "2023-04-05T00:51:51-07:00",
          "data": {
            "paginateKey": 16415,
            "pageIndex": 1,
            "totalPages": 1,
            "totalItems": 2,
            "currentItemCount": 2,
            "itemsPerPage": 10,
            "pagingLinkTemplate": "https://webservices.collegenet.com/r25ws/wrd/partners/run/external/event/list.json?current_cont_id=754&paginate=16415&page={index}&sort=event_name&order=asc",
            "items": [
              {
                "kind": "event",
                "id": 63065,
                "etag": "00000022",
                "eventName": "Academic Cabinet",
                "eventLocator": "2019-AAHVAC",
                "updated": "2019-06-13T10:05:20-07:00",
                "dates": {
                  "startDate": "2019-01-01T00:00:00-08:00",
                  "endDate": "2050-12-31T23:59:00-08:00"
                }
              },
              {
                "kind": "event",
                "id": 63066,
                "etag": "00000023",
                "eventName": "Event Cabinet",
                "eventLocator": "2019-AAHVAD",
                "updated": "2019-06-13T10:21:03-07:00",
                "dates": {
                  "startDate": "2019-01-01T00:00:00-08:00",
                  "endDate": "2050-12-31T23:59:00-08:00"
                }
              }
            ]
          }
        }
      })
    else
      response.status_code = 500
      response << "expected list events request"
    end
  end

  events = Array(TwentyFiveLivePro::Models::Event).from_json(list_events.get.not_nil!.to_json)
  events.size.should eq 2
end
