require "placeos-driver/spec"

DriverSpecs.mock_driver "Extron::UsbExtenderPlus::Endpoint" do
  # On connect it queries the state of the device
  should_send("2f03f4a2000000000300".hexbytes)
  responds ("2f03f4a200000000030100" + "00155d569914" + "BC091BEC625A").hexbytes

  status[:joined_to].should eq ["00155d569914", "bc091bec625a"]
  status[:is_host].should be_true
  status[:mac_address].should eq "ffffffffffff"

  req = exec(:unjoin, "00155D569914")
  should_send("2f03f4a202000000030300155d569914".hexbytes)
  responds "2f03f4a2020000000003".hexbytes

  # account for delay of 600ms
  sleep 0.6

  should_send("2f03f4a2000000000300".hexbytes)
  responds ("2f03f4a200000000030101" + "BC091BEC625A").hexbytes

  req.get

  status[:joined_to].should eq ["bc091bec625a"]
  status[:is_host].should be_false

  sleep 0.3

  req = exec(:join, "000000000000")
  should_send("2f03f4a2020000000302000000000000".hexbytes)
  responds "2f03f4a2020000000003".hexbytes

  sleep 0.6

  should_send("2f03f4a2000000000300".hexbytes)
  responds ("2f03f4a200000000030100" + "BC091BEC625A" + "000000000000").hexbytes

  req.get

  status[:joined_to].should eq ["bc091bec625a", "000000000000"]
  status[:is_host].should be_true
end
