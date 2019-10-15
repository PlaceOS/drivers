EngineSpec.mock_driver "Cisco::Switch::SnoopingCatalyst" do
  transmit "SG-MARWFA61301>"
  sleep 1.5.seconds

  should_send "show interfaces status\n"
  transmit "show interfaces status\n"
  status[:hostname].should eq("SG-MARWFA61301")

  transmit %(Port      Name               Status       Vlan       Duplex  Speed Type
Gi1/0/1                      notconnect   113          auto   auto 10/100/1000BaseTX
Gi1/0/2                      notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/11                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/12                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/13                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/14                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/15                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/16                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi2/0/17                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi3/0/8                      connected    33           auto   auto 10/100/1000BaseTX
 --More--)

  should_send " "
  transmit %(
Gi4/0/48                     notconnect   113          auto   auto 10/100/1000BaseTX
Gi4/1/1                      notconnect   1            auto   auto unknown
Gi4/1/2                      notconnect   1            auto   auto unknown
Te4/1/4                      connected    trunk        full    10G SFP-10GBase-SR
Po1                          connected    trunk      a-full  a-10G
)

  sleep 3.1.seconds

  should_send "show mac address-table\n"
  transmit "show mac address-table\n"

  transmit %(Vlan  MAC               Type        Port
33    e4b9.7aa5.aa7f    STATIC      Gi3/0/8
10    f4db.e618.10a4    DYNAMIC     Te2/0/40
)

  sleep 3.1.seconds

  should_send "show ip dhcp snooping binding\n"
  transmit %(MacAddress          IpAddress        Lease(sec)  Type           VLAN  Interface
------------------  ---------------  ----------  -------------  ----  --------------------
38:C9:86:17:A2:07   192.168.1.15     19868       dhcp-snooping   113   tenGigabitEthernet4/1/4
E4:B9:7A:A5:AA:7F   10.151.128.150   16532       dhcp-snooping   33    GigabitEthernet3/0/8
00:21:CC:D5:33:F4   10.151.130.1     16283       dhcp-snooping   113   GigabitEthernet3/0/34
Total number of bindings: 3

)

  status["devices"].should eq({
    "gi3/0/8" => {
      "mac" => "e4b97aa5aa7f",
      "ip"  => "10.151.128.150",
    },
  })

  status["interfaces"].should eq(["gi3/0/8"])
end
