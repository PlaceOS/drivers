require "placeos-driver/spec"

DriverSpecs.mock_driver "Lutron::ViveLeap" do
  puts "---- Confirming protocol version"
  should_send %({
    "CommuniqueType":"UpdateRequest",
    "Header":{
      "Url":"/clientsetting"
    },
    "Body":{
      "ClientSetting":{
        "ClientMajorVersion":1
      }
    }
  }).gsub(/\s/, "")
  transmit %({
    "CommuniqueType":"UpdateResponse",
    "Header": {
      "MessageBodyType":"OneClientSettingDefinition",
      "StatusCode":"200 OK",
      "Url":"/clientsetting"
    },
    "Body":{
      "ClientSetting":{
        "href":"/clientsetting",
        "ClientMajorVersion":1,
        "ClientMinorVersion":3
      }
    }
  })

  puts "---- Logging on"
  should_send %({
    "CommuniqueType":"UpdateRequest",
    "Header": {"Url":"/login"},
    "Body": {
      "Login":{
        "ContextType":"Application",
        "LoginId":"user",
        "Password":"pass"
      }
    }
  }).gsub(/\s/, "")
  transmit %({
    "CommuniqueType":"UpdateResponse",
    "Header": {
      "StatusCode":"200 OK",
      "Url":"/login"
    }
  })

  puts "---- Testing API"
  status["zonez45"]?.should eq(nil)
  level = exec(:zone_lighting, "z45", true)

  should_send %({
    "CommuniqueType":"CreateRequest",
    "Header":{ "Url":"/zone/z45/commandprocessor" },
    "Body":{
      "Command":{
        "CommandType":"GoToSwitchedLevel",
        "SwitchedLevelParameters":{
          "SwitchedLevel":"On"
        }
      }
    }
  }).gsub(/\s/, "")
  transmit %({
    "CommuniqueType": "CreateResponse",
    "Header":{
      "MessageBodyType":"OneZoneStatus",
      "StatusCode":"200 Created",
      "Url":"/zone/z45/commandprocessor"
    },
    "Body":{
      "ZoneStatus":{
        "href":"/zone/z45/status",
        "SwitchedLevel":"On",
        "Zone":{ "href":"/zone/z45" }
      }
    }
  })

  level.get
  status["zonez45"].should eq(true)
end
