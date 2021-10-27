require "placeos-driver/spec"
require "./collaboration_endpoint/xapi"

DriverSpecs.mock_driver "Cisco::RoomOS" do
  # Test command generation helpers
  action = Cisco::CollaborationEndpoint::XAPI.xcommand(
    "Camera PositionSet",
    camera_id: 1,
    lens: "Wide",
    optional: nil
  )
  action.should eq(%(xCommand Camera PositionSet CameraId: 1 Lens: "Wide"))

  action = Cisco::CollaborationEndpoint::XAPI.xcommand(
    "Audio Volume Decrease"
  )
  action.should eq(%(xCommand Audio Volume Decrease))

  # Test the response processing helpers
  response = JSON.parse(%({
    "Configuration":{
      "Audio":{
        "DefaultVolume":{
          "valueSpaceRef":"/Valuespace/INT_0_100",
          "Value":"50"
        },
        "Input":{
          "Line":[
            {
              "id":"1",
              "VideoAssociation":{
                "MuteOnInactiveVideo":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "VideoInputSource":{
                  "valueSpaceRef":"/Valuespace/TTPAR_PresentationSources_2",
                  "Value":"2"
                }
              }
            }
          ],
          "Microphone":[
            {
              "id":"AAA",
              "EchoControl":{
                "Dereverberation":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"Off"
                },
                "Mode":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "NoiseReduction":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                }
              },
              "Level":{
                "valueSpaceRef":"/Valuespace/INT_0_24",
                "Value":"14"
              },
              "Mode":{
                "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                "Value":"On"
              }
            },
            {
              "id":"2",
              "EchoControl":{
                "Dereverberation":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"Off"
                },
                "Mode":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "NoiseReduction":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                }
              },
              "Level":{
                "valueSpaceRef":"/Valuespace/INT_0_24",
                "Value":"14"
              },
              "Mode":{
                "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                "Value":"On"
              }
            }
          ]
        },
        "Microphones":{
          "Mute":{
            "Enabled":{
              "valueSpaceRef":"/Valuespace/TTPAR_MuteEnabled",
              "Value":"True"
            }
          }
        }
      }
    }
  })).as_h.flatten_xapi_json
  response.should eq({
    "Configuration/Audio/DefaultVolume" => 50,
    "Configuration/Audio/Input/Line/1"  => {
      "VideoAssociation/MuteOnInactiveVideo" => true,
      "VideoAssociation/VideoInputSource"    => 2,
    },
    "Configuration/Audio/Input/Microphone/AAA" => {
      "EchoControl/Dereverberation" => false,
      "EchoControl/Mode"            => true,
      "EchoControl/NoiseReduction"  => true,
      "Level"                       => 14,
      "Mode"                        => true,
    },
    "Configuration/Audio/Input/Microphone/2" => {
      "EchoControl/Dereverberation" => false,
      "EchoControl/Mode"            => true,
      "EchoControl/NoiseReduction"  => true,
      "Level"                       => 14,
      "Mode"                        => true,
    },
    "Configuration/Audio/Microphones/Mute/Enabled" => true,
  })

  transmit "welcome\n*r Login successful\r\n"

  # ====
  # Connection setup
  puts "\nCONNECTION SETUP:\n=============="
  should_send("Echo off\n").responds "\e[?1034h\r\nOK\r\n"
  should_send "xPreferences OutputMode JSON\n"

  # ====
  # System registration
  puts "\nSYSTEM REGISTRATION:\n=============="

  data = String.new expect_send
  data.starts_with?(%(xCommand Peripherals Connect ID: "uuid" Name: "PlaceOS" Type: ControlSystem | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "CommandResponse":{
      "PeripheralsConnectResult":{
        "status":"OK"
      }
    },
    "ResultId": "#{id}"
  })

  # ====
  # Config push
  puts "\nCONFIG PUSH:\n=============="

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Audio Microphones Mute Enabled: "False" | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Audio Input Line 1 VideoAssociation MuteOnInactiveVideo: "On" | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Audio Input Line 1 VideoAssociation VideoInputSource: 2 | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "ResultId": "#{id}"
  })

  # MAPS Status ====
  data = String.new expect_send
  data.starts_with?(%(xFeedback Register /Configuration | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "ResultId": "#{id}"
  })

  should_send "xConfiguration *\n"
  responds %({
    "Configuration":{
      "Audio":{
        "DefaultVolume":{
          "valueSpaceRef":"/Valuespace/INT_0_100",
          "Value":"50"
        },
        "Input":{
          "Line":[
            {
              "id":"1",
              "VideoAssociation":{
                "MuteOnInactiveVideo":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "VideoInputSource":{
                  "valueSpaceRef":"/Valuespace/TTPAR_PresentationSources_2",
                  "Value":"2"
                }
              }
            }
          ],
          "Microphone":[
            {
              "id":"1",
              "EchoControl":{
                "Dereverberation":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"Off"
                },
                "Mode":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "NoiseReduction":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                }
              },
              "Level":{
                "valueSpaceRef":"/Valuespace/INT_0_24",
                "Value":"14"
              },
              "Mode":{
                "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                "Value":"On"
              }
            },
            {
              "id":"2",
              "EchoControl":{
                "Dereverberation":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"Off"
                },
                "Mode":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                },
                "NoiseReduction":{
                  "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                  "Value":"On"
                }
              },
              "Level":{
                "valueSpaceRef":"/Valuespace/INT_0_24",
                "Value":"14"
              },
              "Mode":{
                "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
                "Value":"On"
              }
            }
          ]
        },
        "Microphones":{
          "Mute":{
            "Enabled":{
              "valueSpaceRef":"/Valuespace/TTPAR_MuteEnabled",
              "Value":"True"
            }
          }
        }
      }
    }
  })

  status[:configuration].should eq({
    "/Audio/DefaultVolume" => 50,
    "/Audio/Input/Line/1"  => {
      "VideoAssociation/MuteOnInactiveVideo" => true,
      "VideoAssociation/VideoInputSource"    => 2,
    },
    "/Audio/Input/Microphone/1" => {
      "EchoControl/Dereverberation" => false,
      "EchoControl/Mode"            => true,
      "EchoControl/NoiseReduction"  => true,
      "Level"                       => 14,
      "Mode"                        => true,
    },
    "/Audio/Input/Microphone/2" => {
      "EchoControl/Dereverberation" => false,
      "EchoControl/Mode"            => true,
      "EchoControl/NoiseReduction"  => true,
      "Level"                       => 14,
      "Mode"                        => true,
    },
    "/Audio/Microphones/Mute/Enabled" => true,
  })

  data = String.new expect_send
  puts "GOT: #{data}"
  data.starts_with?(%(xFeedback Register /Status/Audio/Volume | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  puts "GOT: #{data}"
  data.starts_with?(%(xStatus Audio Volume | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
              "Status":{
                  "Audio":{
                      "Volume":{
                          "Value":"50"
                      }
                  }
              },
              "ResultId": "#{id}"
          })

  # Finish mapping status
  status[:volume].should eq(50)

  # ====
  # Audio Status
  resp = exec(:xstatus, "Audio")
  data = String.new expect_send
  data.starts_with?(%(xStatus Audio | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
              "Status":{
                  "Audio":{
                      "Input":{
                          "Connectors":{
                              "Microphone":[
                                  {
                                      "id":"1",
                                      "ConnectionStatus":{
                                          "Value":"Connected"
                                      }
                                  },
                                  {
                                      "id":"2",
                                      "ConnectionStatus":{
                                          "Value":"NotConnected"
                                      }
                                  }
                              ]
                          }
                      },
                      "Microphones":{
                          "Mute":{
                              "Value":"On"
                          }
                      },
                      "Output":{
                          "Connectors":{
                              "Line":[
                                  {
                                      "id":"1",
                                      "DelayMs":{
                                          "Value":"0"
                                      }
                                  }
                              ]
                          }
                      },
                      "Volume":{
                          "Value":"50"
                      }
                  }
              },
              "ResultId": "#{id}"
          })
  resp.get.should eq({
    "Status/Audio/Input/Connectors/Microphone/1" => {
      "ConnectionStatus" => "Connected",
    },
    "Status/Audio/Input/Connectors/Microphone/2" => {
      "ConnectionStatus" => "NotConnected",
    },
    "Status/Audio/Microphones/Mute"         => true,
    "Status/Audio/Output/Connectors/Line/1" => {
      "DelayMs" => 0,
    },
    "Status/Audio/Volume" => 50,
  })

  # ====
  # Time Status
  resp = exec(:xstatus, "Time")
  data = String.new expect_send
  data.starts_with?(%(xStatus Time | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
      "Status":{
          "Time":{
              "SystemTime":{
                  "Value":"2017-11-27T15:14:25+1000"
              }
          }
      },
      "ResultId": "#{id}"
  })

  resp.get.should eq({
    "Status/Time/SystemTime" => "2017-11-27T15:14:25+1000",
  })

  # ====
  # Time Status fail
  resp = exec(:xstatus, "Wrong")
  data = String.new expect_send
  data.starts_with?(%(xStatus Wrong | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "Status":{
      "status":"Error",
      "Reason":{
        "Value":"No match on address expression."
      },
      "XPath":{
        "Value":"Status/Wrong"
      }
    },
    "ResultId": "#{id}"
  })

  expect_raises(PlaceOS::Driver::RemoteException) { resp.get }

  # Basic command
  resp = exec(:xcommand, "Standby Deactivate")
  data = String.new expect_send
  data.starts_with?(%(xCommand Standby Deactivate | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "CommandResponse":{
      "StandbyDeactivateResult":{
        "status":"OK"
      }
    },
    "ResultId": "#{id}"
  })
  resp.get.should eq "OK"

  # Command with arguments
  resp = exec(:xcommand, command: "Video Input SetMainVideoSource", hash_args: {ConnectorId: 1, Layout: :PIP})
  data = String.new expect_send
  data.starts_with?(%(xCommand Video Input SetMainVideoSource ConnectorId: 1 Layout: "PIP" | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "CommandResponse":{
      "InputSetMainVideoSourceResult":{
        "status":"OK"
      }
    },
    "ResultId": "#{id}"
  })
  resp.get.should eq "OK"

  # Return device argument errors
  resp = exec(:xcommand, command: "Video Input SetMainVideoSource", hash_args: {ConnectorId: 1, SourceId: 1})
  data = String.new expect_send
  data.starts_with?(%(xCommand Video Input SetMainVideoSource ConnectorId: 1 SourceId: 1 | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "CommandResponse":{
      "InputSetMainVideoSourceResult":{
        "status":"Error",
        "Reason":{
          "Value":"Must supply either SourceId or ConnectorId (but not both.)"
        }
      }
    },
    "ResultId": "#{id}"
  })

  expect_raises(PlaceOS::Driver::RemoteException) { resp.get }

  # Return error from invalid / inaccessable xCommands
  resp = exec(:xcommand, "Not A Real Command")
  data = String.new expect_send
  data.starts_with?(%(xCommand Not A Real Command | resultId=")).should be_true
  id = data.split('"')[-2]

  responds %({
    "CommandResponse":{
      "Result":{
        "status":"Error",
        "Reason":{
          "Value":"Unknown command"
        }
      },
      "XPath":{
        "Value":"/Not/A/Real/Command"
      }
    },
    "ResultId": "#{id}"
  })

  expect_raises(PlaceOS::Driver::RemoteException) { resp.get }

  # Multiline commands
  resp = exec(:xcommand, "SystemUnit SignInBanner Set", "Hello\nWorld!")
  data = String.new expect_send
  data.starts_with?(%(xCommand SystemUnit SignInBanner Set | resultId=")).should be_true
  data.ends_with?(%(Hello\nWorld!\n.\n)).should be_true
  id = data.split('"')[-2]

  responds %({
      "CommandResponse":{
          "SignInBannerSetResult":{
              "status":"OK"
          }
      },
      "ResultId": "#{id}"
  })

  resp.get.should eq "OK"

  # Multuple settings return a unit :success when all ok
  resp = exec(:xconfiguration, "Video Input Connector 1", {InputSourceType: :Camera, Name: "Borris", Quality: :Motion})
  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 InputSourceType: "Camera" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 Name: "Borris" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 Quality: "Motion" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "ResultId": "#{id}"
  })

  resp.get.should eq true

  # Multiple settings with failure with return a command failure
  resp = exec(:xconfiguration, "Video Input Connector 1", {InputSourceType: :Camera, Foo: "Bar", Quality: :Motion})
  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 InputSourceType: "Camera" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 Foo: "Bar" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "CommandResponse":{
      "Configuration":{
        "status":"Error",
        "Reason":{
          "Value":"No match on address expression."
        },
        "XPath":{
          "Value":"Configuration/Video/Input/Connector[1]/Foo"
        }
      }
    },
    "ResultId": "#{id}"
  })

  data = String.new expect_send
  data.starts_with?(%(xConfiguration Video Input Connector 1 Quality: "Motion" | resultId=")).should be_true
  id = data.split('"')[-2]
  responds %({
    "ResultId": "#{id}"
  })

  expect_raises(PlaceOS::Driver::RemoteException) { resp.get }

  # Out of order send
  responds %({
              "Status":{
                  "Audio":{
                      "Volume":{
                          "Value":"52"
                      }
                  }
              }
          })

  # Finish mapping status
  status[:volume].should eq(52)
end
