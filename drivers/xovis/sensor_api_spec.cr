require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Xovis::SensorAPI" do
  # =========================
  # GET TOKEN
  # =========================
  retval = exec(:get_token)

  # We should request a new token from Floorsense
  expect_http_request do |request, response|
    auth = request.headers["Authorization"]
    if auth == "Basic YWNjb3VudDpwYXNzd29yZCE="
      response.status_code = 200
      response.output << "jwt_token"
    else
      response.status_code = 401
      puts "invalid auth header #{auth}"
    end
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq("jwt_token")

  # =========================
  # RESET COUNT
  # =========================
  retval = exec(:reset_count)

  # We should request a new token from Floorsense
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <response xmlns:ns2="http://www.xovis.com/common-types" xmlns:ns3="http://www.xovis.com/count-data">
      <sensor-time>2020-05-04T12:34:46Z</sensor-time>
      <request-status>
      <ns2:status>OK</ns2:status>
      </request-status>
      </response>)
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq(true)
  status["sensor_time"].should eq("2020-05-04T12:34:46Z")

  # =========================
  # COUNT DATA
  # =========================
  retval = exec(:count_data)

  # We should request a new token from Floorsense
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output << %(<?xml version="1.0" encoding="UTF-8"?>
    <ns2:count-data xmlns:ns2="http://www.xovis.com/count-data" xmlns:ns3="http://www.xovis.com/count-data">
      <ns2:count-items>
        <ns2:lines>
          <ns2:line name="Line 0" id="0" sensor-type="SINGLE_SENSOR">
            <fw-count>0</fw-count>
            <bw-count>0</bw-count>
          </ns2:line>
        </ns2:lines>
      </ns2:count-items>
      <ns2:sensor-time>2020-05-05T11:20:47+02:00</ns2:sensor-time>
      <ns2:request-status>
        <ns3:status>OK</ns3:status>
      </ns2:request-status>
    </ns2:count-data>)
  end

  # What the function should return (for use in making further requests)
  line_data = [{
    "name"        => "Line 0",
    "id"          => "0",
    "sensor-type" => "SINGLE_SENSOR",
    "counts"      => {
      "fw-count" => 0,
      "bw-count" => 0,
    },
  }]
  retval.get.should eq(line_data)
  status["lines"].should eq(line_data)

  # =========================
  # DEVICE INFO
  # =========================
  retval = exec(:device_status)

  # We should request a new token from Floorsense
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output << <<-XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <ns2:sensor-status xmlns:ns2="http://www.xovis.com/sensor-status"  xmlns:ns3="http://www.xovis.com/sensor-status"  xmlns:ns4="http://www.xovis.com/sensor-status"  xmlns:ns5="http://www.xovis.com/sensor-status"  xmlns:ns6="http://www.xovis.com/sensor-status"  xmlns="http://www.xovis.com/sensor-status">
    <ns2:request-status> <status>OK</status>
    </ns2:request-status> <ns2:sensor-time>2020-05-05T13:11:38+02:00</ns2:sensor-time> <ns2:uptime>81551360</ns2:uptime>
    <ns2:versions>
    <ns3:version type="HW">5</ns3:version>
    <ns3:version type="PROD">AB</ns3:version> <ns3:version type="BOM">E</ns3:version>
    <ns3:version type="PCB">B</ns3:version>
    <ns3:version type="FW">1.2.12</ns3:version> <ns3:version type="SW">4.3.1 (5b57718)</ns3:version>
    </ns2:versions> <ns2:sensor>
    <ns2:serial-number>80:1F:12:73:2F:A4</ns2:serial-number> <ns2:ip-address>192.168.1.115</ns2:ip-address>
    <ns2:name>S01</ns2:name>
    <ns2:group>Test</ns2:group>
    <ns2:type>PC2S</ns2:type>
    <ns2:device-type class="COUNTER_2_S">PC2S</ns2:device-type>
    </ns2:sensor> <ns2:temperatures>
    <ns4:temperature type="die">49.0</ns4:temperature>
    <ns4:temperature type="housing">46.0</ns4:temperature> </ns2:temperatures>
    <ns2:illumination>
    <ns4:gain>8.0</ns4:gain> <ns4:gain-factor>1.20166</ns4:gain-factor> <ns4:gain-ratio>0.0</ns4:gain-ratio> <ns4:exposure>0.0139272</ns4:exposure> <ns4:sufficientIllumination>true</ns4:sufficientIllumination>
    </ns2:illumination> <ns2:sensor-tilt>
    <ns4:enabled>true</ns4:enabled> <ns4:pitch>85.823784</ns4:pitch> <ns4:yaw>8.23138</ns4:yaw> <ns4:vector>
    <x>0.143171</x> <y>0.98707</y> <z>0.0720739</z>
    </ns4:vector>
    <ns4:reconfiguration-required>false</ns4:reconfiguration-required> </ns2:sensor-tilt>
    <ns2:configuration>
    <ns4:is-factory-default>false</ns4:is-factory-default> <ns4:hash>492810AF623279442C87D2D65D4A6240</ns4:hash> <ns4:last-modified>2020-05-05T12:22:10+02:00</ns4:last-modified> <ns4:is-recalibrated>false</ns4:is-recalibrated>
    </ns2:configuration> <ns2:operation>
    <ns5:mode>tracking</ns5:mode> <ns5:framenumber>1018951</ns5:framenumber> <ns5:privacy-mode>1</ns5:privacy-mode> <ns5:user-activated>true</ns5:user-activated> <ns5:timezone offset="+0200">Europe/Zurich</ns5:timezone>
    </ns2:operation> <ns2:multisensor-status>
    <ns6:ms-status>OK</ns6:ms-status>
    <ns6:slaves/> </ns2:multisensor-status> <ns2:network>
    <ns2:hostname>XOVIS-PC</ns2:hostname> <ns2:interface name="eth0">
    <ns2:ip-address>192.168.1.115</ns2:ip-address> <ns2:subnetmask>255.255.255.0</ns2:subnetmask> <ns2:default-gateway>192.168.1.1</ns2:default-gateway> <ns2:dns-servers>
    <ns2:dns>192.168.1.1</ns2:dns> </ns2:dns-servers>
    </ns2:interface> <ns2:ieee8021x>
    <ns2:enabled>false</ns2:enabled>
    <ns2:authorized>false</ns2:authorized> </ns2:ieee8021x>
    </ns2:network> <ns2:ntp-status>
    <ns4:active>true</ns4:active> <ns4:last-successful>2020-05-05T13:06:58+02:00</ns4:last-successful> <ns4:nb-syncs-successful>91</ns4:nb-syncs-successful> <ns4:is-critical>false</ns4:is-critical>
    </ns2:ntp-status> <ns2:remotes>
    <ns4:remote>
    <ns4:server>sensor-support.xovis.com:443</ns4:server> <ns4:ssl>true</ns4:ssl>
    <ns4:trusted-certs>true</ns4:trusted-certs> <ns4:connection-token>true</ns4:connection-token> <ns4:admin-login>true</ns4:admin-login> <ns4:established>true</ns4:established> <ns4:last-successful>2020-05-05T02:11:07+02:00</ns4:last-successful <ns4:last-unsuccessful>2020-05-05T02:02:53+02:00</ns4:last-unsucces <ns4:ignore-proxy>false</ns4:ignore-proxy>
    </ns4:remote> </ns2:remotes>
    </ns2:sensor-status>
    XML
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq(true)
  status["version"].should eq({
    "HW"   => "5",
    "PROD" => "AB",
    "BOM"  => "E",
    "PCB"  => "B",
    "FW"   => "1.2.12",
    "SW"   => "4.3.1 (5b57718)",
  })
  status["temperature"].should eq({
    "die"     => "49.0",
    "housing" => "46.0",
  })
  status["sensor"].should eq({
    "serial-number" => "80:1F:12:73:2F:A4",
    "ip-address"    => "192.168.1.115",
    "name"          => "S01",
    "group"         => "Test",
    "type"          => "PC2S",
    "device-type"   => "PC2S",
  })

  # =========================
  # ALIVE CHECK
  # =========================
  retval = exec(:is_alive?)

  # We should request a new token from Floorsense
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <response xmlns:ns2="http://www.xovis.com/common-types" xmlns:ns3="http://www.xovis.com/count-data">
      <sensor-time>2020-05-04T12:34:46Z</sensor-time>
      <request-status>
        <ns2:status>OK</ns2:status>
      </request-status>
      </response>)
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq(true)

  # =========================
  # CAPACITY DATA
  # =========================
  retval = exec(:capacity_data)

  # We should request a new token from Floorsense
  expect_http_request do |_request, response|
    response.status_code = 200
    response.output << %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <persistence-info xmlns:ns2="http://www.xovis.com/common-types" xmlns="http://www.xovis.com/common">
      <sensor-time>2020-05-05T13:06:06+02:00</sensor-time>
      <request-status>
      	<ns2:status>OK</ns2:status>
      </request-status>
      <count-line-storage>
        <capacity>100</capacity>
      	<count-lines>
          <count-line>
            <name>Line 0</name>
            <id>0</id>
            <first-entry>2020-04-27T11:40:00+02:00</first-entry>
            <last-entry>2020-05-05T13:05:00+02:00</last-entry>
            <entry-count>9</entry-count>
          </count-line>
      	</count-lines>
      </count-line-storage>
      <count-zone-occupancy-storage>
        <capacity>80</capacity>
      	<count-zones>
          <count-zone>
            <name>Zone 0</name>
            <id>0</id>
      			<first-entry>2020-05-05T12:22:00+02:00</first-entry>
      			<last-entry>2020-05-05T13:05:00+02:00</last-entry>
      			<entry-count>1</entry-count>
          </count-zone>
      	</count-zones>
      </count-zone-occupancy-storage>
      <count-zone-in-out-storage>
      	<capacity>80</capacity>
        <count-zones>
          <count-zone>
            <name>Zone 0</name>
            <id>0</id>
            <first-entry>2020-05-05T12:22:00+02:00</first-entry>
            <last-entry>2020-05-05T13:05:00+02:00</last-entry>
            <entry-count>1</entry-count>
        	</count-zone>
      	</count-zones>
      </count-zone-in-out-storage>
      </persistence-info>)
  end

  # What the function should return (for use in making further requests)
  retval.get.should eq(true)
  status["line-counts"].should eq([{
    "name"        => "Line 0",
    "id"          => "0",
    "first-entry" => "2020-04-27T11:40:00+02:00",
    "last-entry"  => "2020-05-05T13:05:00+02:00",
    "entry-count" => 9,
    "capacity"    => 100,
  }])
  status["zone-occupancy-counts"].should eq([{
    "name"        => "Zone 0",
    "id"          => "0",
    "first-entry" => "2020-05-05T12:22:00+02:00",
    "last-entry"  => "2020-05-05T13:05:00+02:00",
    "entry-count" => 1,
    "capacity"    => 80,
  }])
  status["zone-in-out-counts"].should eq([{
    "name"        => "Zone 0",
    "id"          => "0",
    "first-entry" => "2020-05-05T12:22:00+02:00",
    "last-entry"  => "2020-05-05T13:05:00+02:00",
    "entry-count" => 1,
    "capacity"    => 80,
  }])
end
