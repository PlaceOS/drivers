require "placeos-driver/spec"

DriverSpecs.mock_driver "Catchbox::HubDSP" do
  it "should query device information on connect" do
    should_send({
      "rx" => {
        "device" => {
          "name" => nil,
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "device" => {
          "name"     => "Conference Room Hub",
          "firmware" => "1.2.3",
          "hardware" => "v1.0",
          "serial"   => "CB123456",
        },
      },
      "error" => 0,
    }.to_json)

    status[:device_name].should eq("Conference Room Hub")
    status[:firmware_version].should eq("1.2.3")
    status[:hardware_version].should eq("v1.0")
    status[:serial_number].should eq("CB123456")
  end

  it "should query network information on connect" do
    should_send({
      "rx" => {
        "network" => {
          "mac"     => nil,
          "ip_mode" => nil,
          "ip"      => nil,
          "subnet"  => nil,
          "gateway" => nil,
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "network" => {
          "mac"     => "00:B0:D0:63:C2:26",
          "ip_mode" => "Static",
          "ip"      => "192.168.1.100",
          "subnet"  => "255.255.255.0",
          "gateway" => "192.168.1.1",
        },
      },
      "error" => 0,
    }.to_json)

    status[:mac_address].should eq("00:B0:D0:63:C2:26")
    status[:ip_mode].should eq("Static")
    status[:ip_address].should eq("192.168.1.100")
    status[:subnet_mask].should eq("255.255.255.0")
    status[:gateway].should eq("192.168.1.1")
  end

  it "should query microphone status on connect" do
    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {"mute" => nil},
            "mic2" => {"mute" => nil},
            "mic3" => {"mute" => nil},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {
              "mute"      => false,
              "battery"   => 85,
              "signal"    => -45,
              "connected" => true,
            },
            "mic2" => {
              "mute"      => true,
              "battery"   => 72,
              "signal"    => -38,
              "connected" => true,
            },
            "mic3" => {
              "mute"      => false,
              "battery"   => 0,
              "signal"    => 0,
              "connected" => false,
            },
          },
        },
      },
      "error" => 0,
    }.to_json)

    status[:mic1_muted].should eq(false)
    status[:mic1_audio_enabled].should eq(true)
    status[:mic1_battery_level].should eq(85)
    status[:mic1_signal_strength].should eq(-45)
    status[:mic1_connected].should eq(true)

    status[:mic2_muted].should eq(true)
    status[:mic2_audio_enabled].should eq(false)
    status[:mic2_battery_level].should eq(72)
    status[:mic2_signal_strength].should eq(-38)
    status[:mic2_connected].should eq(true)

    status[:mic3_muted].should eq(false)
    status[:mic3_audio_enabled].should eq(true)
    status[:mic3_battery_level].should eq(0)
    status[:mic3_signal_strength].should eq(0)
    status[:mic3_connected].should eq(false)
  end

  it "should mute a specific microphone" do
    exec(:mute_mic, 1, true)
    # test
    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {"mute" => true},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {"mute" => true},
          },
        },
      },
      "error" => 0,
    }.to_json)

    status[:mic1_muted].should eq(true)
    status[:mic1_audio_enabled].should eq(false)
  end

  it "should unmute a specific microphone" do
    exec(:unmute_mic, 2)

    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic2" => {"mute" => false},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic2" => {"mute" => false},
          },
        },
      },
      "error" => 0,
    }.to_json)

    status[:mic2_muted].should eq(false)
    status[:mic2_audio_enabled].should eq(true)
  end

  it "should set device name" do
    exec(:set_device_name, "New Room Name")

    should_send({
      "rx" => {
        "device" => {
          "name" => "New Room Name",
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "device" => {
          "name" => "New Room Name",
        },
      },
      "error" => 0,
    }.to_json)

    status[:device_name].should eq("New Room Name")
  end

  it "should configure network settings" do
    exec(:set_network_config, "Static", "192.168.2.100", "255.255.255.0", "192.168.2.1")

    should_send({
      "rx" => {
        "network" => {
          "ip_mode" => "Static",
          "ip"      => "192.168.2.100",
          "subnet"  => "255.255.255.0",
          "gateway" => "192.168.2.1",
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "network" => {
          "ip_mode" => "Static",
          "ip"      => "192.168.2.100",
          "subnet"  => "255.255.255.0",
          "gateway" => "192.168.2.1",
        },
      },
      "error" => 0,
    }.to_json)

    status[:ip_mode].should eq("Static")
    status[:ip_address].should eq("192.168.2.100")
    status[:subnet_mask].should eq("255.255.255.0")
    status[:gateway].should eq("192.168.2.1")
  end

  it "should handle network reboot command" do
    exec(:network_reboot)

    should_send({
      "rx" => {
        "network" => {
          "reboot" => true,
        },
      },
    }.to_json + "\n")

    responds({
      "rx"    => {} of String => JSON::Any,
      "error" => 0,
    }.to_json)
  end

  it "should mute all microphones" do
    exec(:mute_all_mics)

    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {"mute" => true},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic1" => {"mute" => true},
          },
        },
      },
      "error" => 0,
    }.to_json)

    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic2" => {"mute" => true},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic2" => {"mute" => true},
          },
        },
      },
      "error" => 0,
    }.to_json)

    should_send({
      "rx" => {
        "audio" => {
          "input" => {
            "mic3" => {"mute" => true},
          },
        },
      },
    }.to_json + "\n")

    responds({
      "rx" => {
        "audio" => {
          "input" => {
            "mic3" => {"mute" => true},
          },
        },
      },
      "error" => 0,
    }.to_json)

    status[:mic1_muted].should eq(true)
    status[:mic2_muted].should eq(true)
    status[:mic3_muted].should eq(true)
  end

  it "should handle API errors gracefully" do
    exec(:query_device_info)

    should_send({
      "rx" => {
        "device" => {
          "name" => nil,
        },
      },
    }.to_json + "\n")

    responds({
      "rx"    => {} of String => JSON::Any,
      "error" => 1,
    }.to_json)
  end

  it "should validate microphone number range" do
    expect_raises(ArgumentError, "Mic number must be 1, 2, or 3") do
      exec(:mute_mic, 0, true).get
    end

    expect_raises(ArgumentError, "Mic number must be 1, 2, or 3") do
      exec(:mute_mic, 4, true).get
    end
  end
end
