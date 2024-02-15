require "placeos-driver/spec"
require "random"

DriverSpecs.mock_driver "Extron::UsbExtenderPlus::VirtualSwitcher" do
  system({
    USB_Host:   {EndpointMock, EndpointMock},
    USB_Device: {EndpointMock, EndpointMock},
  })

  exec(:switch_to, 1).get

  host1_mac = system(:USB_Host_1)["mac_address"].as_s
  host2_mac = system(:USB_Host_2)["mac_address"].as_s
  dev1_mac = system(:USB_Device_1)["mac_address"].as_s
  dev2_mac = system(:USB_Device_2)["mac_address"].as_s

  system(:USB_Device_1)["joined_to"].should eq [host1_mac]
  system(:USB_Device_2)["joined_to"].should eq [host1_mac]
  system(:USB_Host_1)["joined_to"].should eq [dev1_mac, dev2_mac]
  system(:USB_Host_2)["joined_to"].should eq [] of String

  exec(:switch_to, 2).get
  system(:USB_Device_1)["joined_to"].should eq [host2_mac]
  system(:USB_Device_2)["joined_to"].should eq [host2_mac]
  system(:USB_Host_1)["joined_to"].should eq [] of String
  system(:USB_Host_2)["joined_to"].should eq [dev1_mac, dev2_mac]

  exec(:switch, {1 => [2]}).get
  sleep 0.1
  system(:USB_Device_1)["joined_to"].should eq [host2_mac]
  system(:USB_Device_2)["joined_to"].should eq [host1_mac]
  system(:USB_Host_1)["joined_to"].should eq [dev2_mac]
  system(:USB_Host_2)["joined_to"].should eq [dev1_mac]

  exec(:switch, {1 => [1], 2 => [2]}).get
  sleep 0.1
  system(:USB_Device_1)["joined_to"].should eq [host1_mac]
  system(:USB_Device_2)["joined_to"].should eq [host2_mac]
  system(:USB_Host_1)["joined_to"].should eq [dev1_mac]
  system(:USB_Host_2)["joined_to"].should eq [dev2_mac]
end

# :nodoc:
class EndpointMock < DriverSpecs::MockDriver
  @joined_to : Array(String) = [] of String

  def on_load
    self[:mac_address] = Random::Secure.hex(6).downcase
    self[:joined_to] = [] of String
  end

  def query_joins
    @joined_to
  end

  def unjoin_all
    self[:joined_to] = @joined_to = [] of String
  end

  def unjoin(from : String | Int32)
    mac = case from
          in Int32
            @joined_to[from]
          in String
            formatted = from.gsub(/\-|\:/, "").downcase
            formatted if @joined_to.includes? formatted
          end

    if mac
      @joined_to.delete(mac)
      self[:joined_to] = @joined_to
    end
  end

  def join(mac : String)
    mac = mac.gsub(/\-|\:/, "").downcase
    @joined_to << mac
    self[:joined_to] = @joined_to
  end
end
