require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Lutron::Lighting" do
  # Module waits for this text to become ready
  transmit "login: "
  should_send "nwk\r\n"
  transmit "connection established\r\n"

  # Perform actions
  response = exec(:scene?, area: 1)
  should_send("?AREA,1,6\r\n")
  responds("~AREA,1,6,2\r\n")
  response.get
  status[:area1].should eq(2)

  transmit "~DEVICE,1,6,9,1\r\n"
  status[:device1_6_led].should eq(1)

  transmit "~AREA,1,6,1\r\n"
  status[:area1].should eq(1)

  transmit "~OUTPUT,53,1,100.00\r\n"
  status[:output53_level].should eq(100.00)

  transmit "~SHADEGRP,26,1,100.00\r\n"
  status[:shadegrp26_level].should eq(100.00)

  exec(:scene, area: 1, scene: 3)
  should_send("#AREA,1,6,3\r\n")
  responds("\r\n")

  should_send("?AREA,1,6\r\n")
  transmit "~AREA,1,6,3\r\n"

  status[:area1].should eq(3)
end
