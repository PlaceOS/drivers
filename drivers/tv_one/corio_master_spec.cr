require "placeos-driver/spec"

DriverSpecs.mock_driver "TvOne::CorioMaster" do
  transmit <<-INIT
    // ===================\r
    //  CORIOmaster - CORIOmax\r
    // ===================\r
    // Command Interface Ready\r
    Please login. Use 'login(username,password)'\r
  INIT

  should_send "login(admin,adminpw)\r\n"
  responds "!Info : User admin Logged In\r\n"
  status[:connected].should be_true
  status[:ready].should be_true

  should_send "Preset.Take\r\n"
  responds <<-RX
    Preset.Take = 1\r
    !Done Preset.Take\r\n
  RX

  status[:preset]?.should eq 1

  should_send "Routing.Preset.PresetList()\r\n"
  responds <<-RX
    !Done Routing.Preset.PresetList()\r\n
  RX
  status[:presets]?.should be_nil

  should_send "Windows\r\n"
  responds <<-RX
    !Done Windows\r\n
  RX
  should_send "Canvases\r\n"
  responds <<-RX
    !Done Canvases\r\n
  RX
  should_send "Layouts\r\n"
  responds <<-RX
    !Done Layouts\r\n
  RX
  should_send "CORIOmax.Serial_Number\r\n"
  responds <<-RX
    CORIOmax.Serial_Number = 2218031005149\r
    !Done CORIOmax.Serial_Number\r\n
  RX
  status[:serial_number].should eq 2218031005149_i64

  should_send "CORIOmax.Software_Version\r\n"
  responds <<-RX
    CORIOmax.Software_Version = V1.30701.P4 Master\r
    !Done CORIOmax.Software_Version\r\n
  RX
  status[:firmware].should eq "V1.30701.P4 Master"

  result = exec(:query_windows)
  should_send("Windows\r\n")
  responds(
    <<-RX
        Windows.Window1 = <...>\r
        Windows.Window2 = <...>\r
        !Done Windows\r\n
    RX
  )
  should_send("window1\r\n")
  responds(
    <<-RX
        Window1.FullName = Window1\r
        Window1.Alias = NULL\r
        Window1.Input = Slot3.In1\r
        Window1.Canvas = Canvas1\r
        Window1.CanWidth = 1280\r
        Window1.CanHeight = 720\r
        !Done Window1\r\n
    RX
  )
  should_send("window2\r\n")
  responds(
    <<-RX
        Window2.FullName = Window2\r
        Window2.Alias = NULL\r
        Window2.Input = Slot3.In2\r
        Window2.Canvas = Canvas1\r
        Window2.CanWidth = 1280\r
        Window2.CanHeight = 720\r
        !Done Window2\r\n
    RX
  )

  result.get.should eq({
    "window1" => {
      "fullname"  => "Window1",
      "alias"     => nil,
      "input"     => "Slot3.In1",
      "canvas"    => "Canvas1",
      "canwidth"  => 1280,
      "canheight" => 720,
    },
    "window2" => {
      "fullname"  => "Window2",
      "alias"     => nil,
      "input"     => "Slot3.In2",
      "canvas"    => "Canvas1",
      "canwidth"  => 1280,
      "canheight" => 720,
    },
  })

  result = exec(:preset_list)
  should_send("Routing.Preset.PresetList()\r\n")
  responds(
    <<-RX
      Routing.Preset.PresetList[1]=Sharing-Standard,Canvas1,0\r
      Routing.Preset.PresetList[2]=Standard-4-Screen,Canvas1,0\r
      Routing.Preset.PresetList[3]=Standard-10-Screen,Canvas1,0\r
      Routing.Preset.PresetList[11]=Clear,Canvas1,0\r
      !Done Routing.Preset.PresetList()\r\n
    RX
  )
  result.get.should eq({
    "1"  => {"name" => "Sharing-Standard", "canvas" => "Canvas1", "time" => 0},
    "2"  => {"name" => "Standard-4-Screen", "canvas" => "Canvas1", "time" => 0},
    "3"  => {"name" => "Standard-10-Screen", "canvas" => "Canvas1", "time" => 0},
    "11" => {"name" => "Clear", "canvas" => "Canvas1", "time" => 0},
  })

  result = exec(:preset, 1)
  should_send("Preset.Take = 1\r\n")
  responds(
    <<-RX
      Preset.Take = 1\r
      !Done Preset.Take\r\n
    RX
  )

  result.get.should eq 1
  status[:preset]?.should eq 1

  should_send("Windows\r\n")
  responds(
    <<-RX
        Windows.Window1 = <...>\r
        !Done Windows\r\n
    RX
  )
  should_send("window1\r\n")
  responds(
    <<-RX
        Window1.FullName = Window1\r
        Window1.Alias = NULL\r
        Window1.Input = Slot3.In1\r
        Window1.Canvas = Canvas1\r
        Window1.CanWidth = 1280\r
        Window1.CanHeight = 720\r
        !Done Window1\r\n
    RX
  )

  status[:windows]?.should eq({
    "window1" => {
      "fullname"  => "Window1",
      "alias"     => nil,
      "input"     => "Slot3.In1",
      "canvas"    => "Canvas1",
      "canwidth"  => 1280,
      "canheight" => 720,
    },
  })

  exec(:switch, {"Slot1.In1" => [1]})
  should_send("Window1.Input = Slot1.In1\r\n")
  responds(
    <<-RX
      Window1.Input = Slot1.In1\r
      !Done Window1.Input\r\n
    RX
  )

  status[:windows]["window1"]["input"].should eq("Slot1.In1")
end
