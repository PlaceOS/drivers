require "placeos-driver/spec"
require "./models/**"

DriverSpecs.mock_driver "Delta::API" do
  # List sites

  list_sites = exec :list_sites

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Collection",
        "nodeType": "PROTOCOL",
        "Random Name": {
            "$base": "Collection",
            "nodeType": "NETWORK",
            "truncated": "true"
        }
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  sites = Array(String).from_json(list_sites.get.not_nil!.to_json)
  sites.first.should eq "Random Name"

  # List devices by site name

  list_devices_by_site_name = exec(:list_devices_by_site_name, "Random Name")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet/Random%20Name?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Collection",
        "251": {
            "$base": "Collection",
            "displayName": "Test",
            "nodeType": "DEVICE",
            "truncated": "true"
        },
        "200": {
            "$base": "Collection",
            "displayName": "Test",
            "nodeType": "DEVICE",
            "truncated": "true"
        },
        "253": {
            "$base": "Collection",
            "displayName": "Test",
            "nodeType": "DEVICE",
            "truncated": "true"
        },
        "254": {
            "$base": "Collection",
            "displayName": "Test",
            "nodeType": "DEVICE",
            "truncated": "true"
        },
        "260": {
            "$base": "Collection",
            "displayName": "Test",
            "nodeType": "DEVICE",
            "truncated": "true"
        }
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  devices = Array(Delta::Models::Device).from_json(list_devices_by_site_name.get.not_nil!.to_json)
  devices.first.display_name.should eq "Test"

  # List objects by device number
  list_objects_by_device_number = exec(:list_objects_by_device_number, "Random Name", "200")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet/Random%20Name/200?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Collection",
        "nodeType": "Device",
        "analog-input,83": {
            "$base": "Object",
            "displayName": "CPU Board Temperature",
            "truncated": "true"
          },
        "analog-input,84": {
            "$base": "Object",
            "displayName": "APU Board Temperature",
            "truncated": "true"
          }
        })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  devices = Array(Delta::Models::Object).from_json(list_objects_by_device_number.get.not_nil!.to_json)
  devices.first.display_name.should eq "CPU Board Temperature"

  # Get value property by object type through instance
  get_value_property_by_object_type_through_instance = exec(:get_value_property_by_object_type_through_instance, "Random Name", "200", "A", "B")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet/Random%20Name/200/A%2CB?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Object",
        "displayName": "DEL1__AI1_85",
        "object-identifier": {
            "$base": "ObjectIdentifier",
            "value": "del,1"
        },
        "object-type": {
            "$base": "Enumerated",
            "value": "data-exchange-local-data"
        },
        "object-name": {
            "$base": "String",
            "value": "DEL1__AI1_85"
        },
        "exchange-flags": {
            "$base": "BitString",
            "value": ""
        },
        "exchange-type": {
            "$base": "Enumerated",
            "value": "optimized-broadcast"
        },
        "last-error": {
            "$base": "Signed",
            "value": 0
        },
        "local-ref": {
            "$base": "Sequence",
            "type": "0-BACnetDeviceObjectPropertyReference",
            "deviceIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "device,251"
            },
            "objectIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "analog-input,1"
            },
            "propertyIdentifier": {
                "$base": "Enumerated",
                "value": "present-value",
                "type": "0-BACnetPropertyIdentifier"
            }
        },
        "local-flags": {
            "$base": "BitString",
            "value": "not-commissioned"
        },
        "local-value": {
            "$base": "Choice",
            "real": {
                "$base": "Real",
                "value": "1"
            }
        },
        "subscribers": {
            "$base": "Array",
            "1": {
                "$base": "Sequence",
                "subscriber": {
                    "$base": "Choice",
                    "device": {
                        "$base": "ObjectIdentifier",
                        "value": "200"
                    }
                },
                "id": {
                    "$base": "Unsigned",
                    "value": 0
                },
                "useConfirmed": {
                    "$base": "Boolean",
                    "value": 0
                },
                "flags": {
                    "$base": "BitString",
                    "value": ""
                },
                "refreshTimer": {
                    "$base": "Choice",
                    "refreshTimer": {
                        "$base": "Unsigned",
                        "value": "478568103"
                    }
                }
            }
        },
        "last-sent": {
            "$base": "Unsigned",
            "value": 0
        },
        "send-frequency": {
            "$base": "Unsigned",
            "value": 0
        },
        "cov-increment": {
            "$base": "Real",
            "value": 0
        }
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  value_property = Delta::Models::ValueProperty.from_json(get_value_property_by_object_type_through_instance.get.not_nil!.to_json)
  value_property.display_name.should eq "DEL1__AI1_85"

  # Get value property by object type through property name
  get_value_property_by_object_type_through_property_name = exec(:get_value_property_by_object_type_through_property_name, "Random Name", "200", "A", "B")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet/Random%20Name/200/A%2CB?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Object",
        "displayName": "DEL1__AI1_85",
        "object-identifier": {
            "$base": "ObjectIdentifier",
            "value": "del,1"
        },
        "object-type": {
            "$base": "Enumerated",
            "value": "data-exchange-local-data"
        },
        "object-name": {
            "$base": "String",
            "value": "DEL1__AI1_85"
        },
        "exchange-flags": {
            "$base": "BitString",
            "value": ""
        },
        "exchange-type": {
            "$base": "Enumerated",
            "value": "optimized-broadcast"
        },
        "last-error": {
            "$base": "Signed",
            "value": 0
        },
        "local-ref": {
            "$base": "Sequence",
            "type": "0-BACnetDeviceObjectPropertyReference",
            "deviceIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "device,251"
            },
            "objectIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "analog-input,1"
            },
            "propertyIdentifier": {
                "$base": "Enumerated",
                "value": "present-value",
                "type": "0-BACnetPropertyIdentifier"
            }
        },
        "local-flags": {
            "$base": "BitString",
            "value": "not-commissioned"
        },
        "local-value": {
            "$base": "Choice",
            "real": {
                "$base": "Real",
                "value": "1"
            }
        },
        "subscribers": {
            "$base": "Array",
            "1": {
                "$base": "Sequence",
                "subscriber": {
                    "$base": "Choice",
                    "device": {
                        "$base": "ObjectIdentifier",
                        "value": "200"
                    }
                },
                "id": {
                    "$base": "Unsigned",
                    "value": 0
                },
                "useConfirmed": {
                    "$base": "Boolean",
                    "value": 0
                },
                "flags": {
                    "$base": "BitString",
                    "value": ""
                },
                "refreshTimer": {
                    "$base": "Choice",
                    "refreshTimer": {
                        "$base": "Unsigned",
                        "value": "478568103"
                    }
                }
            }
        },
        "last-sent": {
            "$base": "Unsigned",
            "value": 0
        },
        "send-frequency": {
            "$base": "Unsigned",
            "value": 0
        },
        "cov-increment": {
            "$base": "Real",
            "value": 0
        }
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  value_property = Delta::Models::ValueProperty.from_json(get_value_property_by_object_type_through_property_name.get.not_nil!.to_json)
  value_property.display_name.should eq "DEL1__AI1_85"

  # Get value property by object type through subproperty path
  get_value_property_by_object_type_through_subproperty_path = exec(:get_value_property_by_object_type_through_subproperty_path, "Random Name", "200", "A", "B")

  expect_http_request do |request, response|
    case "#{request.path}?#{request.query}"
    when "/api/.bacnet/Random%20Name/200/A%2CB?alt=json"
      response.status_code = 200
      response << %({
        "$base": "Object",
        "displayName": "DEL1__AI1_85",
        "object-identifier": {
            "$base": "ObjectIdentifier",
            "value": "del,1"
        },
        "object-type": {
            "$base": "Enumerated",
            "value": "data-exchange-local-data"
        },
        "object-name": {
            "$base": "String",
            "value": "DEL1__AI1_85"
        },
        "exchange-flags": {
            "$base": "BitString",
            "value": ""
        },
        "exchange-type": {
            "$base": "Enumerated",
            "value": "optimized-broadcast"
        },
        "last-error": {
            "$base": "Signed",
            "value": 0
        },
        "local-ref": {
            "$base": "Sequence",
            "type": "0-BACnetDeviceObjectPropertyReference",
            "deviceIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "device,251"
            },
            "objectIdentifier": {
                "$base": "ObjectIdentifier",
                "value": "analog-input,1"
            },
            "propertyIdentifier": {
                "$base": "Enumerated",
                "value": "present-value",
                "type": "0-BACnetPropertyIdentifier"
            }
        },
        "local-flags": {
            "$base": "BitString",
            "value": "not-commissioned"
        },
        "local-value": {
            "$base": "Choice",
            "real": {
                "$base": "Real",
                "value": "1"
            }
        },
        "subscribers": {
            "$base": "Array",
            "1": {
                "$base": "Sequence",
                "subscriber": {
                    "$base": "Choice",
                    "device": {
                        "$base": "ObjectIdentifier",
                        "value": "200"
                    }
                },
                "id": {
                    "$base": "Unsigned",
                    "value": 0
                },
                "useConfirmed": {
                    "$base": "Boolean",
                    "value": 0
                },
                "flags": {
                    "$base": "BitString",
                    "value": ""
                },
                "refreshTimer": {
                    "$base": "Choice",
                    "refreshTimer": {
                        "$base": "Unsigned",
                        "value": "478568103"
                    }
                }
            }
        },
        "last-sent": {
            "$base": "Unsigned",
            "value": 0
        },
        "send-frequency": {
            "$base": "Unsigned",
            "value": 0
        },
        "cov-increment": {
            "$base": "Real",
            "value": 0
        }
      })
    else
      response.status_code = 500
      response << "expected token request"
    end
  end

  value_property = Delta::Models::ValueProperty.from_json(get_value_property_by_object_type_through_subproperty_path.get.not_nil!.to_json)
  value_property.display_name.should eq "DEL1__AI1_85"
end
