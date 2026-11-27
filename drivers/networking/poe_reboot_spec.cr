require "placeos-driver/spec"
require "snmp"

# A loopback SNMP agent using the wire formats the driver uses on switches.
private class PoeSwitchFixture
  ADMIN       = "1.3.6.1.2.1.105.1.1.1.3.1.4"
  ENTITY_OID  = "1.3.6.1.2.1.47.1.3.2.1.2.200.0"
  DHCP_ENTRY  = "1.3.6.1.4.1.9.9.380.1.4.1.1"
  MAC_INDEX   = "0.17.34.51.68.85"
  ENGINE_ID   = "8000000001020304"
  DEVICE_IP   = "192.0.2.42"
  SWITCH_IP   = "127.0.0.1"
  COMMUNITY   = "poe-spec"
  V3_USERNAME = "poe-user"
  V3_AUTH     = "test-auth-password"
  V3_PRIV     = "test-priv-password"

  getter port : Int32
  getter writes = [] of Tuple(String, Int32)
  getter scopes = Set(String).new
  property admin = 1
  property catalyst = false
  property advertise_vlan = true
  property shared = false
  property lose_disable_reply = false
  property reject_enable = false
  property fdb_present = true
  property fdb_status : Int32? = 3
  property dhcp_ip : String? = nil
  property dhcp_vlan = 42
  property dhcp_interface = 10104
  property dhcp_status = 1
  property dhcp_lease = 300_u32
  property dhcp_reads_remaining : Int32? = nil
  property bridge_port_mapped = true
  property bridge_if_index = 10104
  property read_neighbors = true
  property dns_neighbors = false
  property dns_conflicting_neighbors = false
  property legacy_arp = false
  property cisco_mapping = true
  property stack_mapping = false
  property cisco_mode = 1
  property shared_fdb = false

  def initialize(host : String = SWITCH_IP, port : Int32 = 0)
    @socket = UDPSocket.new(Socket::IPAddress.new(host, port).family)
    @socket.bind(host, port)
    @port = @socket.local_address.port
    @v3 = SNMP::V3::Session.new(SNMP::V3::Security.new(V3_USERNAME, ENGINE_ID,
      auth_protocol: :sha256, auth_password: V3_AUTH, priv_protocol: :aes, priv_password: V3_PRIV))
    @v3.reboot
    spawn { serve }
  end

  def close
    @socket.close
  end

  private def serve
    buffer = Bytes.new(65_535)
    until @socket.closed?
      length, address = @socket.receive(buffer)
      packet = IO::Memory.new(buffer[0, length]).read_bytes(ASN1::BER)
      v3 = packet.children.first.get_integer == SNMP::Version::V3.value
      if v3
        params = SNMP::V3::SecurityParams.new(packet.children[2])
        request = @v3.parse(packet, params.engine_id.empty? ? nil : @v3.security)
      else
        request = SNMP::Session.new.parse(packet)
      end

      response = reply_to(request)
      if response
        wire = IO::Memory.new
        wire.write_bytes(response)
        @socket.send(wire.to_slice, address)
      end
    end
  rescue error : IO::Error
    raise error unless @socket.closed?
  end

  private def reply_to(request : SNMP::Message) : ASN1::BER?
    if request.is_a?(SNMP::V3::Message) && request.engine_id.empty?
      pdu = SNMP::PDU.new(request.request_id, [SNMP::VarBind.new("1.3.6.1.6.3.15.1.1.4.0")])
      scoped = SNMP::V3::ScopedPDU.new(SNMP::Request::Report, pdu, ENGINE_ID)
      params = SNMP::V3::SecurityParams.new(engine_id: ENGINE_ID, engine_boots: 1)
      return SNMP::V3::Message.new(scoped, params, id: request.id).to_ber
    end

    scope = if request.is_a?(SNMP::V3::Message)
              request.scoped_pdu.context
            else
              request.community.split('@', 2)[1]?.try { |vlan| "community@#{vlan}" } || ""
            end
    @scopes << scope
    rows = table(scope)
    error = SNMP::ErrorStatus::NoError
    bindings = case request.request
               when .get_bulk?
                 cursor = oid_arcs(request.oid)
                 # The shard decodes the GetBulk max-repetitions slot as error_index.
                 values = rows.values.select { |value| oid_arcs(value.oid) > cursor }
                   .sort_by { |value| oid_arcs(value.oid) }.first(request.error_index)
                 values.empty? ? [exception_binding(request.oid, 2)] : values
               when .get?
                 if (remaining = @dhcp_reads_remaining) && remaining > 0 && request.oid.starts_with?("#{DHCP_ENTRY}.3.")
                   @dhcp_reads_remaining = remaining - 1
                 end
                 request.varbinds.map { |binding| rows[binding.oid]? || exception_binding(binding.oid, 1) }
               when .set?
                 value = request.varbind.get_integer.to_i
                 @writes << {request.oid, value}
                 if request.oid != ADMIN || (value == 1 && @reject_enable)
                   error = SNMP::ErrorStatus::NotWritable
                 else
                   @admin = value
                 end
                 return nil if value == 2 && @lose_disable_reply
                 request.varbinds
               else
                 raise "Unexpected SNMP request #{request.request}"
               end

    if request.is_a?(SNMP::V3::Message)
      pdu = SNMP::PDU.new(request.request_id, bindings, error)
      scoped = SNMP::V3::ScopedPDU.new(SNMP::Request::Response, pdu, ENGINE_ID, scope)
      params = SNMP::V3::SecurityParams.new(V3_USERNAME, ENGINE_ID, 1, 0)
      response = SNMP::V3::Message.new(scoped, params, @v3.security, id: request.id)
      @v3.prepare(response)
    else
      SNMP::Message.new(request.community, SNMP::Request::Response, bindings, request.request_id, error).to_ber
    end
  end

  private def oid_arcs(oid : String)
    oid.split('.').map(&.to_i)
  end

  private def exception_binding(oid, tag)
    missing = ASN1::BER.new
    missing.tag_class = ASN1::BER::TagClass::ContextSpecific
    missing.tag_number = tag
    SNMP::VarBind.from_value(oid, missing)
  end

  private def table(scope)
    rows = Hash(String, SNMP::VarBind).new
    if scope.empty?
      if (ip = @dhcp_ip) && @dhcp_reads_remaining != 0
        suffix = "#{@dhcp_vlan}.#{MAC_INDEX}"
        octets = ip.split('.').map(&.to_u8)
        values = {3 => 1, 4 => ASN1::BER.new.set_bytes(Bytes.new(4) { |index| octets[index] }),
                  5 => @dhcp_interface, 6 => SNMP::Gauge32.new(@dhcp_lease), 7 => @dhcp_status}
        values.each do |column, value|
          oid = "#{DHCP_ENTRY}.#{column}.#{suffix}"
          rows[oid] = SNMP::VarBind.from_value(oid, value)
        end
      end
      if @read_neighbors
        mac = ASN1::BER.new.set_bytes(Bytes[0, 17, 34, 51, 68, 85])
        if @legacy_arp
          arp_oid = "1.3.6.1.2.1.4.22.1.2.20.192.0.2.42"
          type_oid = "1.3.6.1.2.1.4.22.1.4.20.192.0.2.42"
          rows[arp_oid] = SNMP::VarBind.from_value(arp_oid, mac)
          rows[type_oid] = SNMP::VarBind.from_value(type_oid, 3)
        else
          neighbors = ["20.1.4.192.0.2.42", "20.2.16.32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.66"]
          loopback_v6 = "20.2.16.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.1"
          neighbors.concat(["20.1.4.127.0.0.1", loopback_v6]) if @dns_neighbors
          neighbors.each do |neighbor|
            mac_oid = "1.3.6.1.2.1.4.35.1.4.#{neighbor}"
            type_oid = "1.3.6.1.2.1.4.35.1.6.#{neighbor}"
            neighbor_mac = if @dns_conflicting_neighbors && neighbor == loopback_v6
                             ASN1::BER.new.set_bytes(Bytes[0, 17, 34, 51, 68, 86])
                           else
                             mac
                           end
            rows[mac_oid] = SNMP::VarBind.from_value(mac_oid, neighbor_mac)
            rows[type_oid] = SNMP::VarBind.from_value(type_oid, 3)
          end
        end
      end
      rows[ADMIN] = SNMP::VarBind.from_value(ADMIN, @admin)
      rows["1.3.6.1.2.1.105.1.1.1.6.1.4"] = SNMP::VarBind.from_value("1.3.6.1.2.1.105.1.1.1.6.1.4", @admin == 1 ? 3 : 2)
      rows["1.3.6.1.2.1.31.1.1.1.1.10104"] = SNMP::VarBind.from_value("1.3.6.1.2.1.31.1.1.1.1.10104", ASN1::BER.new.set_bytes("Gi1/0/4".to_slice))
      if @cisco_mapping
        rows["1.3.6.1.4.1.9.9.402.1.2.1.11.1.4"] = SNMP::VarBind.from_value("1.3.6.1.4.1.9.9.402.1.2.1.11.1.4", 200)
        rows["1.3.6.1.4.1.9.9.402.1.2.1.1.1.4"] = SNMP::VarBind.from_value("1.3.6.1.4.1.9.9.402.1.2.1.1.1.4", @cisco_mode)
        if @stack_mapping
          # The STACK-MIB row index differs from the POWER-ETHERNET-MIB index.
          stack_entity = "1.3.6.1.4.1.9.5.1.4.1.1.25.2.8"
          stack_if_index = "1.3.6.1.4.1.9.5.1.4.1.1.11.2.8"
          rows[stack_entity] = SNMP::VarBind.from_value(stack_entity, 200)
          rows[stack_if_index] = SNMP::VarBind.from_value(stack_if_index, 10104)
        else
          rows[ENTITY_OID] = SNMP::VarBind.from_value(ENTITY_OID, ASN1::BER.new.set_object_id("1.3.6.1.2.1.2.2.1.1.10104"))
        end
      end
      if @catalyst
        vid_oid = "1.3.6.1.4.1.9.9.46.1.3.1.1.2.1.42"
        rows[vid_oid] = SNMP::VarBind.from_value(vid_oid, 1) if @advertise_vlan
      else
        vlan_oid = "1.3.6.1.2.1.17.7.1.4.2.1.3.0.42"
        rows[vlan_oid] = SNMP::VarBind.from_value(vlan_oid, SNMP::Gauge32.new(17_u32))
        if @shared_fdb
          other_vid = "1.3.6.1.2.1.17.7.1.4.2.1.3.0.43"
          rows[other_vid] = SNMP::VarBind.from_value(other_vid, SNMP::Gauge32.new(17_u32))
        end
        add_fdb(rows, "1.3.6.1.2.1.17.7.1.2.2.1", "17.", 7) if @fdb_present
      end
    elsif @catalyst && {"community@42", "vlan-42"}.includes?(scope)
      add_fdb(rows, "1.3.6.1.2.1.17.4.3.1", "", 14) if @fdb_present
    end
    rows
  end

  private def add_fdb(rows, table, index_prefix, port)
    mapped_port = @bridge_port_mapped ? port : port + 1
    bridge_oid = "1.3.6.1.2.1.17.1.4.1.2.#{mapped_port}"
    rows[bridge_oid] = SNMP::VarBind.from_value(bridge_oid, @bridge_if_index)
    indices = [MAC_INDEX]
    indices << "0.17.34.51.68.86" if @shared
    indices.each do |mac|
      port_oid = "#{table}.2.#{index_prefix}#{mac}"
      status_oid = "#{table}.3.#{index_prefix}#{mac}"
      rows[port_oid] = SNMP::VarBind.from_value(port_oid, port)
      if status = @fdb_status
        rows[status_oid] = SNMP::VarBind.from_value(status_oid, status)
      end
    end
  end
end

DriverSpecs.mock_driver "Networking::PoeReboot" do
  fixture = PoeSwitchFixture.new
  gateway = PoeSwitchFixture.new("127.0.0.2", fixture.port)
  target = PoeSwitchFixture::DEVICE_IP
  host = PoeSwitchFixture::SWITCH_IP
  defaults = {
    switch_ips: [host], device_ips: [target], mac_prefixes: ["00-11-22"],
    snmp: {version: "v2c", community: PoeSwitchFixture::COMMUNITY, port: fixture.port, timeout: 1},
    reboot_off_seconds: 1,
  }

  it "resolves switch, interface, PoE index and VLAN before cycling power" do
    settings(defaults)
    row = status[:switches][host]["ports"][0]
    row["ip"].should eq(target)
    row["mac"].should eq("00:11:22:33:44:55")
    row["vlan"].should eq(42)
    row["interface_name"].should eq("Gi1/0/4")
    row["if_index"].should eq(10104)
    row["poe_group"].should eq(1)
    row["poe_port"].should eq(4)
    row["delivering_power"].should eq(true)
    fixture.writes.should be_empty

    start = Time.instant
    results = exec(:reboot).get
    start.elapsed.should be >= 1.second
    results[0]["outcome"].should eq("rebooted")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  end

  it "skips wrong manufacturer prefixes and shared ports" do
    fixture.writes.clear
    settings(defaults.merge({mac_prefixes: ["aa:bb:cc"]}))
    status[:unresolved_devices][target].should eq("MAC manufacturer prefix did not match")
    exec(:reboot).get.as_a.should be_empty

    fixture.shared = true
    settings(defaults)
    status[:unresolved_devices][target].should eq("Multiple MAC addresses learned on this interface")
    exec(:reboot).get.as_a.should be_empty
    fixture.shared = false
    fixture.writes.should be_empty
  end

  it "finds a target through a gateway and the Catalyst v2c VLAN context" do
    fixture.catalyst = true
    fixture.read_neighbors = false
    fixture.scopes.clear
    settings(defaults.merge({neighbor_ips: ["127.0.0.2"]}))
    status[:switches][host]["ports"][0]["vlan"].should eq(42)
    fixture.scopes.should contain("community@42")
    fixture.read_neighbors = true
  end

  it "cycles a Catalyst port using authenticated and encrypted SNMPv3" do
    fixture.writes.clear
    fixture.scopes.clear
    settings(defaults.merge({snmp: {
      version: "v3", username: PoeSwitchFixture::V3_USERNAME, port: fixture.port, timeout: 1,
      auth_protocol: "sha256", auth_password: PoeSwitchFixture::V3_AUTH,
      priv_protocol: "aes", priv_password: PoeSwitchFixture::V3_PRIV,
    }}))
    results = exec(:reboot).get
    results[0]["outcome"].should eq("rebooted")
    fixture.scopes.should contain("vlan-42")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
    fixture.catalyst = false
  end

  it "uses the standard VLAN forwarding table with an explicit VLAN" do
    fixture.writes.clear
    settings(defaults.merge({switch_vlans: {host => [42]}}))
    result = exec(:reboot_device, target).get
    result["outcome"].should eq("rebooted")
    status[:switches][host]["ports"][0]["vlan"].should eq(42)
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  end

  it "reboots a Catalyst port when an active DHCP snooping binding corroborates the forwarding row" do
    fixture.writes.clear
    fixture.catalyst = true
    fixture.fdb_status = 5
    fixture.dhcp_ip = target
    settings(defaults.merge({switch_vlans: {host => [42]}}))

    row = status[:switches][host]["ports"][0]
    row["verification"].should eq("dhcp_snooping")
    row["vlan"].should eq(42)
    row["if_index"].should eq(10104)
    exec(:reboot_device, target).get["outcome"].should eq("rebooted")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  ensure
    fixture.catalyst = false
    fixture.fdb_status = 3
    fixture.dhcp_ip = nil
  end

  it "uses the default SNMPv3 context for the binding and the VLAN context for forwarding" do
    fixture.writes.clear
    fixture.catalyst = true
    fixture.fdb_status = nil
    fixture.dhcp_ip = target
    settings(defaults.merge({switch_vlans: {host => [42]}, snmp: {
      version: "v3", username: PoeSwitchFixture::V3_USERNAME, port: fixture.port, timeout: 1,
      auth_protocol: "sha256", auth_password: PoeSwitchFixture::V3_AUTH,
      priv_protocol: "aes", priv_password: PoeSwitchFixture::V3_PRIV,
    }}))

    status[:switches][host]["ports"][0]["verification"].should eq("dhcp_snooping")
    exec(:reboot_device, target).get["outcome"].should eq("rebooted")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  ensure
    fixture.catalyst = false
    fixture.fdb_status = 3
    fixture.dhcp_ip = nil
  end

  it "leaves the port powered when DHCP snooping corroboration is missing or mismatched" do
    fixture.writes.clear
    fixture.fdb_status = 5
    settings(defaults)
    [
      {nil, 42, 10104, 1, 300_u32},
      {"192.0.2.43", 42, 10104, 1, 300_u32},
      {target, 43, 10104, 1, 300_u32},
      {target, 42, 10105, 1, 300_u32},
      {target, 42, 10104, 2, 300_u32},
      {target, 42, 10104, 1, 0_u32},
    ].each do |ip, vlan, interface, row_status, lease|
      fixture.dhcp_ip = ip
      fixture.dhcp_vlan = vlan
      fixture.dhcp_interface = interface
      fixture.dhcp_status = row_status
      fixture.dhcp_lease = lease
      expect_raises(PlaceOS::Driver::RemoteException, /no matching active DHCP snooping binding/) do
        exec(:reboot_device, target).get
      end
    end
    fixture.writes.should be_empty
  ensure
    fixture.fdb_status = 3
    fixture.dhcp_ip = nil
    fixture.dhcp_vlan = 42
    fixture.dhcp_interface = 10104
    fixture.dhcp_status = 1
    fixture.dhcp_lease = 300_u32
  end

  it "rejects invalid forwarding rows and keeps DHCPv4 corroboration specific to the bound IP" do
    fixture.writes.clear
    fixture.dhcp_ip = target
    settings(defaults.merge({device_ips: [target, "2001:db8::42"]}))
    {2, 4}.each do |fdb_status|
      fixture.fdb_status = fdb_status
      expect_raises(PlaceOS::Driver::RemoteException, /forwarding status #{fdb_status}/) do
        exec(:reboot_device, target).get
      end
    end
    fixture.fdb_status = 5
    exec(:query_state).get
    status[:switches][host]["ports"].as_a.map(&.["ip"].as_s).should eq([target])
    expect_raises(PlaceOS::Driver::RemoteException, /no matching active DHCP snooping binding/) do
      exec(:reboot_device, "2001:db8::42").get
    end
    fixture.writes.should be_empty
  ensure
    fixture.fdb_status = 3
    fixture.dhcp_ip = nil
  end

  it "checks the DHCP snooping binding again before writing PoE admin state" do
    fixture.writes.clear
    fixture.fdb_status = 5
    fixture.dhcp_ip = target
    settings(defaults)
    fixture.dhcp_reads_remaining = 1

    result = exec(:reboot_device, target).get
    result["outcome"].should eq("failed")
    result["error"].should eq("DHCP snooping binding changed before reboot")
    fixture.writes.should be_empty
  ensure
    fixture.fdb_status = 3
    fixture.dhcp_ip = nil
    fixture.dhcp_reads_remaining = nil
  end

  it "does not assign a shared filtering database to a configured VLAN" do
    fixture.writes.clear
    fixture.shared_fdb = true
    settings(defaults.merge({switch_vlans: {host => [43]}}))
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty
  ensure
    fixture.shared_fdb = false
  end

  it "joins Cisco STACK-MIB rows by ENTITY index when ENTITY aliases are absent" do
    fixture.writes.clear
    fixture.stack_mapping = true
    settings(defaults)
    result = exec(:reboot_device, target).get
    result["outcome"].should eq("rebooted")
    status[:switches][host]["ports"][0]["if_index"].should eq(10104)
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  ensure
    fixture.stack_mapping = false
  end

  it "reports a learned VLAN port that lacks a verified PoE mapping" do
    fixture.writes.clear
    fixture.catalyst = true
    fixture.cisco_mapping = false
    settings(defaults.merge({switch_vlans: {host => [42]}}))

    reason = status[:unresolved_devices][target].as_s
    reason.should contain("00:11:22:33:44:55")
    reason.should contain("Gi1/0/4")
    reason.should contain("ifIndex 10104")
    reason.should contain("VLAN 42")
    reason.should contain("no verified PoE mapping")
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty

    settings(defaults.merge({
      switch_vlans:      {host => [42]},
      poe_port_mappings: {host => {"10104" => {group: 1, port: 4}}},
    }))
    status[:switches][host]["ports"][0]["poe_port"].should eq(4)
  ensure
    fixture.catalyst = false
    fixture.cisco_mapping = true
  end

  it "reports a VLAN forwarding entry with no bridge-to-interface mapping" do
    fixture.writes.clear
    fixture.catalyst = true
    fixture.bridge_port_mapped = false
    settings(defaults.merge({switch_vlans: {host => [42]}}))

    reason = status[:unresolved_devices][target].as_s
    reason.should contain("bridge port 14")
    reason.should contain("VLAN 42")
    reason.should contain("ifIndex")
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty
  ensure
    fixture.catalyst = false
    fixture.bridge_port_mapped = true
  end

  it "rejects an explicit mapping that claims another interface's Cisco PoE port" do
    fixture.writes.clear
    fixture.bridge_if_index = 10105
    settings(defaults.merge({
      poe_port_mappings: {host => {"10104" => {group: 1, port: 5}, "10105" => {group: 1, port: 4}}},
    }))

    status[:unresolved_devices][target].as_s.should contain("ifIndex 10105")
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty
  ensure
    fixture.bridge_if_index = 10104
  end

  it "supports an explicit non-Cisco mapping and leaves a shared FDB VLAN unknown" do
    fixture.cisco_mapping = false
    fixture.shared_fdb = true
    settings(defaults.merge({poe_port_mappings: {host => {"10104" => {group: 1, port: 4}}}}))
    row = status[:switches][host]["ports"][0]
    row["poe_port"].should eq(4)
    row["vlan"]?.should be_nil
    fixture.cisco_mapping = true
    fixture.shared_fdb = false
  end

  it "skips Cisco static PoE mode and blocks an ambiguous switch match" do
    fixture.writes.clear
    fixture.cisco_mode = 2
    settings(defaults)
    status[:unresolved_devices][target].should eq("Cisco PoE mode is not auto")
    exec(:reboot).get.as_a.should be_empty
    fixture.cisco_mode = 1

    settings(defaults.merge({switch_ips: [host, "127.0.0.2"]}))
    status[:unresolved_devices][target].should eq("MAC is on multiple powered PoE ports")
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty
    gateway.writes.should be_empty
  end

  it "resolves legacy ARP and cycles one port once for IPv4 and IPv6 aliases" do
    fixture.legacy_arp = true
    settings(defaults)
    status[:switches][host]["ports"][0]["ip"].should eq(target)
    fixture.legacy_arp = false

    fixture.writes.clear
    ipv6 = "2001:db8::42"
    settings(defaults.merge({device_ips: [target, ipv6]}))
    results = exec(:reboot).get.as_a
    results.size.should eq(1)
    results.first["ips"].as_a.map(&.as_s).should eq([target, ipv6])
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  end

  it "requires current topology and reachable switches before writing" do
    fixture.writes.clear
    settings(defaults)
    fixture.fdb_present = false
    exec(:reboot).get.as_a.should be_empty
    status[:unresolved_devices][target].should eq("No learned forwarding entry for MAC 00:11:22:33:44:55")
    fixture.fdb_present = true

    settings(defaults.merge({switch_ips: [host, "127.0.0.3"], neighbor_ips: [host]}))
    # An initial poll may still be running while the other switch times out.
    deadline = Time.instant + 3.seconds
    until status[:switches]["127.0.0.3"]?.try(&.["error"]?.try(&.as_s?)) || Time.instant >= deadline
      sleep 25.milliseconds
    end
    exec(:reboot).get.as_a.should be_empty
    status[:last_reboot]["blocked"].should eq("Discovery incomplete")
    fixture.writes.should be_empty
  end

  it "restores power after an unacknowledged disable" do
    fixture.writes.clear
    fixture.lose_disable_reply = true
    settings(defaults)
    results = exec(:reboot).get
    results[0]["outcome"].should eq("failed")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
    fixture.admin.should eq(1)
    fixture.lose_disable_reply = false
  end

  it "records a failed restore and retries it on the next discovery" do
    settings(defaults)
    fixture.writes.clear
    fixture.reject_enable = true
    results = exec(:reboot).get
    results[0]["outcome"].should eq("restore_pending")
    status[:pending_restore]["index"]["port"].should eq(4)
    fixture.admin.should eq(2)

    fixture.reject_enable = false
    exec(:query_state).get
    status[:pending_restore]?.should be_nil
    fixture.admin.should eq(1)
  end

  it "reboots a single device by IP without replacing the configured inventory" do
    fixture.writes.clear
    settings(defaults)
    discovery = status[:switches]
    last_discovery = status[:last_discovery]
    individual = "2001:db8::42"

    result = exec(:reboot_device, device_ip: individual).get
    result["outcome"].should eq("rebooted")
    result["ips"].as_a.map(&.as_s).should eq([individual])
    result["switch_ip"].should eq(host)
    status[:switches].should eq(discovery)
    status[:last_discovery].should eq(last_discovery)
    status[:last_reboot]["results"][0].should eq(result)
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  end

  it "requires a fresh, allow-listed and unambiguous IP match" do
    fixture.writes.clear
    settings(defaults)
    fixture.fdb_present = false
    expect_raises(PlaceOS::Driver::RemoteException, /No learned forwarding entry/) do
      exec(:reboot_device, target).get
    end
    fixture.fdb_present = true

    settings(defaults.merge({mac_prefixes: ["aa:bb:cc"]}))
    expect_raises(PlaceOS::Driver::RemoteException, /MAC manufacturer prefix did not match/) do
      exec(:reboot_device, target).get
    end

    settings(defaults.merge({switch_ips: [host, "127.0.0.2"]}))
    expect_raises(PlaceOS::Driver::RemoteException, /MAC is on multiple powered PoE ports/) do
      exec(:reboot_device, target).get
    end
    fixture.writes.should be_empty
    gateway.writes.should be_empty
  end

  it "cycles an explicit PSE port without a neighbor entry or interface mapping" do
    fixture.writes.clear
    fixture.cisco_mapping = false
    settings(defaults.merge({device_ips: [] of String, mac_prefixes: [] of String}))

    result = exec(:reboot_port, switch_ip: host, port: 4).get
    result["outcome"].should eq("rebooted")
    result["switch_ip"].should eq(host)
    result["poe_group"].should eq(1)
    result["poe_port"].should eq(4)
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])

    fixture.writes.clear
    wrong_group = exec(:reboot_port, switch_ip: host, port: 4, group: 2).get
    wrong_group["outcome"].should eq("failed")
    expect_raises(PlaceOS::Driver::RemoteException, /outside switch_ips/) do
      exec(:reboot_port, switch_ip: "127.0.0.2", port: 4).get
    end
    fixture.writes.should be_empty
    gateway.writes.should be_empty
    fixture.cisco_mapping = true
  end

  it "cycles a switch port identified by its exact interface name" do
    fixture.writes.clear
    settings(defaults)
    result = exec(:reboot_port, host, "Gi1/0/4").get
    result["outcome"].should eq("rebooted")
    result["poe_port"].should eq(4)
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])

    fixture.writes.clear
    expect_raises(PlaceOS::Driver::RemoteException, /unavailable or ambiguous/) do
      exec(:reboot_port, host, "Gi1/0/").get
    end
    fixture.writes.should be_empty
  end

  it "recovers an explicit port from a journal without an ifIndex" do
    settings(defaults)
    fixture.reject_enable = true
    result = exec(:reboot_port, host, 4).get
    result["outcome"].should eq("restore_pending")
    status[:pending_restore]["if_index"]?.should be_nil
    fixture.admin.should eq(2)

    expect_raises(PlaceOS::Driver::RemoteException, /Power restoration pending/) do
      exec(:reboot_device, target).get
    end

    fixture.reject_enable = false
    exec(:query_state).get
    status[:pending_restore]?.should be_nil
    fixture.admin.should eq(1)
  end

  it "accepts names for switch, neighbor, device, VLAN and PoE mapping settings" do
    fixture.writes.clear
    fixture.scopes.clear
    fixture.dns_neighbors = true
    fixture.catalyst = true
    fixture.advertise_vlan = false
    fixture.cisco_mapping = false
    settings(defaults.merge({
      switch_ips:        [host, "localhost"],
      device_ips:        ["localhost"],
      neighbor_ips:      ["LOCALHOST"],
      switch_vlans:      {"LOCALHOST" => [42]},
      poe_port_mappings: {"localhost" => {"10104" => {group: 1, port: 4}}},
    }))

    switch = status[:switches]["localhost"]
    switch["ip"].should eq(host)
    switch["ports"].as_a.map { |port| port["ip"].as_s }.sort.should eq([host, "::1"].sort)
    switch["ports"][0]["vlan"].should eq(42)
    fixture.scopes.should contain("community@42")

    results = exec(:reboot).get.as_a
    results.size.should eq(1)
    results.first["outcome"].should eq("rebooted")
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
  ensure
    fixture.dns_neighbors = false
    fixture.catalyst = false
    fixture.advertise_vlan = true
    fixture.cisco_mapping = true
  end

  it "accepts hostnames in both individual reboot commands" do
    fixture.writes.clear
    fixture.dns_neighbors = true
    settings(defaults)

    result = exec(:reboot_port, switch_ip: "LOCALHOST", port: "Gi1/0/4").get
    result["outcome"].should eq("rebooted")
    result["switch_ip"].should eq(host)
    result = exec(:reboot_device, device_ip: "LOCALHOST").get
    result["outcome"].should eq("rebooted")
    result["ips"].as_a.map(&.as_s).sort.should eq([host, "::1"].sort)
    fixture.writes.map(&.last).should eq([2, 1, 2, 1])

    fixture.writes.clear
    fixture.dns_conflicting_neighbors = true
    expect_raises(PlaceOS::Driver::RemoteException, /multiple MAC addresses/) do
      exec(:reboot_device, "localhost").get
    end
    fixture.writes.should be_empty
  ensure
    fixture.dns_neighbors = false
    fixture.dns_conflicting_neighbors = false
  end

  it "matches a dual-stack DNS alias to an IPv6 switch address" do
    switch = PoeSwitchFixture.new("::1", fixture.port)
    begin
      switch.cisco_mapping = false
      settings(defaults.merge({
        switch_ips:        ["::1"],
        poe_port_mappings: {"localhost" => {"10104" => {group: 1, port: 4}}},
      }))

      result = exec(:reboot_port, switch_ip: "localhost", port: "Gi1/0/4").get
      result["outcome"].should eq("rebooted")
      result["switch_ip"].should eq("::1")
      switch.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
    ensure
      switch.close
    end
  end

  it "rejects conflicting switch settings that refer to the same IP" do
    fixture.writes.clear
    settings(defaults.merge({
      poe_port_mappings: {
        host        => {"10104" => {group: 1, port: 4}},
        "localhost" => {"10104" => {group: 2, port: 4}},
      },
    }))
    status[:switches][host]["error"].as_s.should contain("Conflicting switch settings")
    exec(:reboot).get.as_a.should be_empty
    fixture.writes.should be_empty
  end

  it "restores PoE to the journaled IP after the switch name moves" do
    fixture.writes.clear
    gateway.writes.clear
    gateway.cisco_mapping = false
    gateway.admin = 2
    settings(defaults.merge({
      switch_ips:        ["localhost"],
      poe_port_mappings: {"localhost" => {"10104" => {group: 1, port: 4}}},
    }))
    status[:switches]["localhost"]["ip"].should eq(host)
    status[:pending_restore] = {
      switch_name: "localhost",
      switch_ip:   "127.0.0.2",
      if_index:    10104,
      index:       {group: 1, port: 4},
    }

    exec(:query_state).get
    fixture.writes.should be_empty
    gateway.writes.should eq([{PoeSwitchFixture::ADMIN, 1}])
    gateway.admin.should eq(1)
    status[:pending_restore]?.should be_nil
  ensure
    gateway.cisco_mapping = true
    gateway.admin = 1
    status[:pending_restore] = nil
  end

  it "reports invalid reboot schedule settings" do
    settings(defaults.merge({reboot_cron: "0 3 * * 0", reboot_timezone: "Not/AZone"}))
    status[:configuration_error].should eq("Invalid reboot_cron or reboot_timezone")
  end

  it "runs the configured reboot cron in its configured timezone" do
    fixture.writes.clear
    location = Time::Location.load("Australia/Sydney")
    start = Time.local(location) + 3.seconds
    cron = "#{start.second} #{start.minute} #{start.hour} * * *"
    settings(defaults.merge({reboot_cron: cron, reboot_timezone: "Australia/Sydney"}))

    deadline = Time.instant + 6.seconds
    until fixture.writes.size >= 2 || Time.instant >= deadline
      sleep 25.milliseconds
    end
    fixture.writes.should eq([{PoeSwitchFixture::ADMIN, 2}, {PoeSwitchFixture::ADMIN, 1}])
    settings(defaults)
  end

  fixture.close
  gateway.close
end
