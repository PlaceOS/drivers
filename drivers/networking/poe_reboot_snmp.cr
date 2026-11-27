require "json"
require "snmp"

module Networking
  # IP-MIB: https://www.rfc-editor.org/rfc/rfc4293.html
  # BRIDGE-MIB: https://www.rfc-editor.org/rfc/rfc4188.html
  # Q-BRIDGE-MIB: https://www.rfc-editor.org/rfc/rfc4363.html
  # ENTITY-MIB: https://www.rfc-editor.org/rfc/rfc4133.html
  # POWER-ETHERNET-MIB: https://www.rfc-editor.org/rfc/rfc3621.html
  # Catalyst VLAN contexts: https://www.cisco.com/c/en/us/support/docs/ip/simple-network-management-protocol-snmp/44800-mactoport44800.html
  # Cisco PoE mapping: https://github.com/cisco/cisco-mibs/blob/main/v2/CISCO-POWER-ETHERNET-EXT-MIB.my
  # Cisco physical port cross-reference: https://github.com/cisco/cisco-mibs/blob/main/v2/CISCO-STACK-MIB.my
  # Cisco VLAN state: https://github.com/cisco/cisco-mibs/blob/main/v2/CISCO-VTP-MIB.my
  # Cisco dynamic DHCP bindings: https://github.com/cisco/cisco-mibs/blob/main/v2/CISCO-DHCP-SNOOPING-MIB.my
  module PoeRebootSnmp
    NEIGHBOR_MAC    = "1.3.6.1.2.1.4.35.1.4"
    NEIGHBOR_TYPE   = "1.3.6.1.2.1.4.35.1.6"
    ARP_MAC         = "1.3.6.1.2.1.4.22.1.2"
    ARP_TYPE        = "1.3.6.1.2.1.4.22.1.4"
    BRIDGE_IFINDEX  = "1.3.6.1.2.1.17.1.4.1.2"
    BRIDGE_FDB      = "1.3.6.1.2.1.17.4.3.1"
    VLAN_FDB        = "1.3.6.1.2.1.17.7.1.2.2.1"
    VLAN_FDB_ID     = "1.3.6.1.2.1.17.7.1.4.2.1.3"
    IF_INDEX        = "1.3.6.1.2.1.2.2.1.1"
    IF_NAME         = "1.3.6.1.2.1.31.1.1.1.1"
    ENTITY_ALIAS    = "1.3.6.1.2.1.47.1.3.2.1.2"
    PSE_ADMIN       = "1.3.6.1.2.1.105.1.1.1.3"
    PSE_DETECTION   = "1.3.6.1.2.1.105.1.1.1.6"
    CISCO_PSE_MODE  = "1.3.6.1.4.1.9.9.402.1.2.1.1"
    CISCO_PSE_ENT   = "1.3.6.1.4.1.9.9.402.1.2.1.11"
    CISCO_STACK_ENT = "1.3.6.1.4.1.9.5.1.4.1.1.25"
    CISCO_STACK_IF  = "1.3.6.1.4.1.9.5.1.4.1.1.11"
    CISCO_VLAN      = "1.3.6.1.4.1.9.9.46.1.3.1.1.2"
    CISCO_VLAN_TYPE = "1.3.6.1.4.1.9.9.46.1.3.1.1.3"
    CISCO_TRUNK     = "1.3.6.1.4.1.9.9.46.1.6.1.1.14"
    DHCP_BINDINGS   = "1.3.6.1.4.1.9.9.380.1.4.1.1"

    ENABLED    = 1
    DISABLED   = 2
    DELIVERING = 3

    enum FdbStatus
      Other      = 1
      Invalid    = 2
      Learned    = 3
      Self       = 4
      Management = 5
    end

    class Credentials
      include JSON::Serializable

      getter version : String = "v2c"
      getter community : String = ""
      getter username : String = ""
      getter auth_protocol : SNMP::V3::Security::AuthProtocol = :sha
      getter auth_password : String = ""
      getter priv_protocol : SNMP::V3::Security::PrivacyProtocol = :aes
      getter priv_password : String = ""
      getter port : Int32 = 161
      getter timeout : Int32 = 3

      def validate
        raise ArgumentError.new("snmp.port must be between 1 and 65535") unless (1..65535).includes?(port)
        raise ArgumentError.new("snmp.timeout must be positive") unless timeout > 0

        case version
        when "v2c", "v2"
          raise ArgumentError.new("snmp.community is required for SNMPv2c") if community.empty?
        when "v3"
          raise ArgumentError.new("snmp.username is required for SNMPv3") if username.empty?
          security
        else
          raise ArgumentError.new("snmp.version must be v2c or v3")
        end
      end

      def agent(host : String) : Agent
        if version == "v3"
          Agent.new(host, SNMP::V3::Session.new(security), timeout: timeout, port: port)
        else
          Agent.new(host, community: community, timeout: timeout, port: port)
        end
      end

      private def security
        SNMP::V3::Security.new(username, auth_protocol: auth_protocol, auth_password: auth_password,
          priv_protocol: priv_protocol, priv_password: priv_password)
      end
    end

    class Agent < SNMP::Client
      @context = ""

      private def build_socket : UDPSocket
        socket = UDPSocket.new(Socket::IPAddress.new(host, port).family)
        socket.sync = false
        socket.read_timeout = timeout.seconds
        socket
      end

      # The shard handles transport and USM. Correlate each reply with its
      # request and select a VLAN's scoped PDU before encoding/signing it.
      private def transceive(socket, message : SNMP::Message) : SNMP::Message
        message.scoped_pdu.context = @context if message.is_a?(SNMP::V3::Message)
        reply = super
        if message.is_a?(SNMP::V3::Message) && reply.is_a?(SNMP::V3::Message)
          raise SNMP::Error.new("SNMPv3 message ID mismatch") unless reply.id == message.id
          return reply if reply.report?

          unless reply.flags.authentication? == message.flags.authentication? &&
                 reply.flags.privacy? == message.flags.privacy? &&
                 reply.security_model == message.security_model &&
                 reply.security_params.username == message.security_params.username &&
                 reply.engine_id == message.engine_id &&
                 reply.scoped_pdu.context_engine_id == message.scoped_pdu.context_engine_id &&
                 reply.scoped_pdu.context == message.scoped_pdu.context
            raise SNMP::Error.new("SNMPv3 security or context mismatch")
          end
        elsif reply.version != message.version || reply.community != message.community
          raise SNMP::Error.new("SNMP version or community mismatch")
        end
        unless reply.request.response? && reply.request_id == message.request_id
          raise SNMP::Error.new("unexpected SNMP response")
        end
        reply
      end

      def in_vlan(vlan : Int32?, &)
        sess = session
        if vlan && sess.is_a?(SNMP::Session)
          agent = Agent.new(host, community: "#{sess.community}@#{vlan}", timeout: timeout, port: port)
          begin
            yield agent
          ensure
            agent.close
          end
        else
          previous_context = @context
          begin
            @context = vlan ? "vlan-#{vlan}" : ""
            yield self
          ensure
            @context = previous_context
          end
        end
      end

      def read(*oids : String) : Array(SNMP::VarBind)
        values = bindings(get(oids))
        raise SNMP::Error.new("unexpected SNMP GET bindings") unless values.map(&.oid) == oids.to_a
        values
      end

      def write_integer(oid : String, value : Int32)
        bindings = bindings(set(oid, value))
        unless bindings.size == 1 && bindings.first.oid == oid && integer(bindings.first) == value
          raise SNMP::Error.new("unexpected SNMP SET bindings for #{oid}")
        end
      end

      def column(base : String, &)
        cursor = base
        cursor_arcs = cursor.split('.').map(&.to_i64)
        prefix = "#{base}."
        loop do
          values = bindings(get_bulk({cursor}, max_repetitions: 20))
          raise SNMP::Error.new("empty SNMP walk response for #{base}") if values.empty?
          values.each do |binding|
            return if binding.exception? || !binding.oid.starts_with?(prefix)
            arcs = binding.oid.split('.').map(&.to_i64)
            unless arcs > cursor_arcs
              raise SNMP::Error.new("SNMP walk did not advance for #{base}")
            end
            cursor = binding.oid
            cursor_arcs = arcs
            yield cursor.byte_slice(base.bytesize + 1), binding
          end
        end
      end

      def integer(binding : SNMP::VarBind) : Int32?
        binding.get_integer.to_i if binding.tag_class.universal? && binding.tag == SNMP::UniversalTags::Integer
      end

      def octets(binding : SNMP::VarBind) : Bytes?
        binding.get_bytes if binding.tag_class.universal? && binding.tag == SNMP::UniversalTags::OctetString
      end

      def object_id(binding : SNMP::VarBind) : String?
        binding.get_object_id if binding.tag_class.universal? && binding.tag == SNMP::UniversalTags::ObjectIdentifier
      end

      private def bindings(reply : SNMP::Message) : Array(SNMP::VarBind)
        unless reply.error_status.no_error?
          raise SNMP::Error.new("SNMP #{reply.error_status} (binding #{reply.error_index})")
        end
        reply.varbinds
      end
    end

    struct PoeIndex
      include JSON::Serializable

      getter group : Int32
      getter port : Int32

      def initialize(@group, @port)
      end

      def to_s(io : IO)
        io << group << '.' << port
      end
    end

    record DhcpBinding, index : String, ip : String

    record FdbLocation, if_index : Int32, bridge_port : Int32, port_oid : String, status_oid : String,
      context_vlan : Int32?, vlan : Int32?, dhcp_binding : DhcpBinding?

    record FdbResult, locations : Hash(String, Array(FdbLocation)) = Hash(String, Array(FdbLocation)).new,
      shared : Set(Int32) = Set(Int32).new,
      issues : Hash(String, Set(String)) = Hash(String, Set(String)).new do
      def add_issue(mac : String, vlan : Int32?, issue : String)
        scope = vlan ? "VLAN #{vlan} forwarding entry" : "Forwarding entry"
        (issues[mac] ||= Set(String).new) << "#{scope} #{issue}"
      end
    end

    private class MissingBridgeMapping < SNMP::Error
    end

    def self.neighbors(agent : Agent, targets : Set(String), result : Hash(String, Set(String)))
      modern = Set(String).new
      agent.column(NEIGHBOR_MAC) do |index, binding|
        arcs = index.split('.')
        length = arcs[2]?.try(&.to_i?)
        next unless arcs.size == 3 + (length || 0)
        ip = case {arcs[1]?, length}
             when {"1", 4}
               arcs[3..].join('.')
             when {"2", 16}
               groups = arcs[3..].in_groups_of(2, "0").map { |pair| ((pair[0].to_i << 8) | pair[1].to_i).to_s(16) }
               Socket::IPAddress.new(groups.join(':'), 0).address
             end
        next unless ip && targets.includes?(ip)
        modern << ip
        # Ignore local and invalid rows.
        type = agent.integer(agent.read("#{NEIGHBOR_TYPE}.#{index}").first)
        next if type && type != 3 && type != 4
        if address = agent.octets(binding).try { |bytes| mac(bytes) }
          (result[ip] ||= Set(String).new) << address
        end
      end

      return if targets.all? { |ip| modern.includes?(ip) || ip.includes?(':') }
      agent.column(ARP_MAC) do |index, binding|
        arcs = index.split('.', 2)
        ip = arcs[1]?
        next unless ip && targets.includes?(ip) && !modern.includes?(ip)
        type = agent.integer(agent.read("#{ARP_TYPE}.#{index}").first)
        next if type && type != 3 && type != 4
        if address = agent.octets(binding).try { |bytes| mac(bytes) }
          (result[ip] ||= Set(String).new) << address
        end
      end
    end

    def self.poe_ports(agent : Agent, configured : Hash(Int32, PoeIndex)) : Hash(Int32, PoeIndex)
      entities = Hash(Int32, Array(PoeIndex)).new
      agent.column(CISCO_PSE_ENT) do |index, binding|
        group, port = index.split('.').map(&.to_i)
        entity = agent.integer(binding)
        next unless group > 0 && port > 0 && entity && entity > 0
        (entities[entity] ||= [] of PoeIndex) << PoeIndex.new(group, port)
      end

      indices = Hash(Int32, Set(PoeIndex)).new
      unless entities.empty?
        aliased = Set(Int32).new
        agent.column(ENTITY_ALIAS) do |index, binding|
          entity = index.partition('.').first.to_i
          rows = entities[entity]?
          next unless rows
          oid = agent.object_id(binding)
          next unless oid && oid.starts_with?("#{IF_INDEX}.")
          if_index = oid.byte_slice(IF_INDEX.bytesize + 1).to_i?
          next unless if_index && if_index > 0
          (indices[if_index] ||= Set(PoeIndex).new).concat(rows)
          aliased << entity
        end

        # Both STACK-MIB columns describe the same port row. Match through
        # entPhysicalIndex because STACK and PoE row indices may differ.
        if aliased.size < entities.size
          agent.column(CISCO_STACK_ENT) do |index, binding|
            entity = agent.integer(binding)
            next unless entity && !aliased.includes?(entity)
            rows = entities[entity]?
            next unless rows
            if_index = agent.integer(agent.read("#{CISCO_STACK_IF}.#{index}").first)
            next unless if_index && if_index > 0
            (indices[if_index] ||= Set(PoeIndex).new).concat(rows)
          end
        end
      end

      owners = Hash(PoeIndex, Set(Int32)).new
      indices.each do |if_index, rows|
        rows.each { |row| (owners[row] ||= Set(Int32).new) << if_index }
      end
      mapped = configured.reject do |if_index, row|
        if interfaces = owners[row]?
          interfaces.size != 1 || !interfaces.includes?(if_index)
        else
          false
        end
      end
      indices.each do |index, rows|
        # A configured mapping must agree with a Cisco mapping if present.
        if rows.size != 1 || owners[rows.first].size != 1 || (configured.has_key?(index) && !rows.includes?(configured[index]))
          mapped.delete(index)
        else
          mapped[index] = rows.first
        end
      end
      counts = mapped.values.tally
      mapped.reject { |_, index| counts[index] != 1 }
    end

    def self.forwarding(agent : Agent, vlans : Array(Int32)?, targets : Hash(String, Set(String))) : FdbResult
      result = FdbResult.new
      first_mac = Hash(Int32, String).new
      missing_q_bridge = nil
      if vlans.nil?
        if read_fdb(agent, agent, VLAN_FDB, nil, vlan_fdb_ids(agent), targets, first_mac, result)
          return result
        end

        vlans = [] of Int32
        agent.column(CISCO_VLAN) do |index, binding|
          vlan = index.rpartition('.').last.to_i
          vlans << vlan if (1..4094).includes?(vlan) && agent.integer(binding) == 1
        end
        unless vlans.empty?
          non_ethernet = Set(Int32).new
          agent.column(CISCO_VLAN_TYPE) do |index, binding|
            type = agent.integer(binding)
            non_ethernet << index.rpartition('.').last.to_i if type && type != 1
          end
          vlans.reject! { |vlan| non_ethernet.includes?(vlan) }
          vlans.uniq!
        end
      elsif !vlans.empty?
        vlan_ids = vlan_fdb_ids(agent)
        if vlans.all? { |vlan| exclusive_fdb?(vlan_ids, vlan) }
          standard = FdbResult.new
          begin
            read_fdb(agent, agent, VLAN_FDB, nil, vlan_ids, targets, Hash(Int32, String).new, standard, vlans)
            return standard unless standard.locations.empty?
          rescue error : MissingBridgeMapping
            missing_q_bridge = error
          end
          result.issues.merge!(standard.issues)
        end
      end

      if vlans.empty?
        read_fdb(agent, agent, BRIDGE_FDB, nil, nil, targets, first_mac, result)
      else
        vlans.each do |vlan|
          agent.in_vlan(vlan) do |scoped|
            read_fdb(scoped, agent, BRIDGE_FDB, vlan, nil, targets, first_mac, result)
          end
        end
      end
      raise missing_q_bridge if missing_q_bridge && result.locations.empty?
      result
    end

    private def self.vlan_fdb_ids(agent : Agent) : Hash(UInt32, Set(Int32))
      # FDB IDs are allocated by the bridge. Several VLANs may share an ID.
      vlan_ids = Hash(UInt32, Set(Int32)).new
      agent.column(VLAN_FDB_ID) do |index, binding|
        vlan = index.rpartition('.').last.to_i
        next unless (1..4094).includes?(vlan)
        (vlan_ids[binding.get_unsigned32] ||= Set(Int32).new) << vlan
      end
      vlan_ids
    end

    private def self.exclusive_fdb?(vlan_ids : Hash(UInt32, Set(Int32)), vlan : Int32) : Bool
      memberships = vlan_ids.values.select(&.includes?(vlan))
      memberships.size == 1 && memberships.first.size == 1
    end

    private def self.read_fdb(agent : Agent, default_agent : Agent, table : String, context_vlan : Int32?, vlan_ids : Hash(UInt32, Set(Int32))?,
                              targets : Hash(String, Set(String)), first_mac : Hash(Int32, String), result : FdbResult,
                              allowed_vlans : Array(Int32)? = nil) : Bool
      ports = Hash(Int32, Int32).new
      seen = false
      agent.column("#{table}.2") do |index, binding|
        seen = true
        arcs = index.split('.')
        next unless arcs.size == (vlan_ids ? 7 : 6)
        address = mac(Bytes.new(6) { |i| arcs[i + (vlan_ids ? 1 : 0)].to_u8 })
        next unless address

        vlans = vlan_ids.try(&.[arcs.first.to_u32]?)
        vlan = context_vlan || (vlans.first if vlans && vlans.size == 1)
        target_ips = (!allowed_vlans || (vlan && allowed_vlans.includes?(vlan))) ? targets[address]? : nil
        bridge_port = agent.integer(binding)
        unless bridge_port && bridge_port > 0
          result.add_issue(address, vlan, "has no usable bridge port") if target_ips
          next
        end

        if ports.empty?
          agent.column(BRIDGE_IFINDEX) do |key, port_binding|
            if_index = agent.integer(port_binding)
            ports[key.to_i] = if_index if if_index && if_index > 0
          end
          if ports.empty?
            scope = " in VLAN #{vlan}" if vlan
            raise MissingBridgeMapping.new("bridge port to interface mapping is unavailable#{scope}")
          end
        end
        if_index = ports[bridge_port]?
        unless if_index
          result.add_issue(address, vlan, "has no ifIndex mapping for bridge port #{bridge_port}") if target_ips
          next
        end
        previous = first_mac[if_index] ||= address
        result.shared << if_index if previous != address
        next unless target_ips
        status_oid = "#{table}.3.#{index}"
        status = agent.read(status_oid).first
        status_value = agent.integer(status)
        dhcp_binding = nil
        unless status_value == FdbStatus::Learned.value
          if vlan && dhcp_corroboration_allowed?(agent, status)
            # MacAddress is fixed-width in this table index.
            binding_index = "#{vlan}.#{address.hexbytes.join('.')}"
            ip = default_agent.in_vlan(nil) { |unscoped| dhcp_binding_ip(unscoped, binding_index, if_index) }
            dhcp_binding = DhcpBinding.new(binding_index, ip) if ip && target_ips.includes?(ip)
          end
          unless dhcp_binding
            reason = "on ifIndex #{if_index} has forwarding status #{status_value || "unavailable"}"
            reason += " and no matching active DHCP snooping binding" if vlan && dhcp_corroboration_allowed?(agent, status)
            result.add_issue(address, vlan, reason)
            next
          end
        end

        (result.locations[address] ||= [] of FdbLocation) << FdbLocation.new(
          if_index, bridge_port, binding.oid, status_oid, context_vlan, vlan, dhcp_binding)
      end
      seen
    end

    def self.dhcp_corroboration_allowed?(agent : Agent, status : SNMP::VarBind) : Bool
      value = agent.integer(status)
      status.no_such_instance? || status.no_such_object? ||
        value == FdbStatus::Other.value || value == FdbStatus::Management.value
    end

    def self.dhcp_binding_ip(agent : Agent, index : String, if_index : Int32) : String?
      address_type, address, interface, lease, status = agent.read(
        "#{DHCP_BINDINGS}.3.#{index}", "#{DHCP_BINDINGS}.4.#{index}", "#{DHCP_BINDINGS}.5.#{index}",
        "#{DHCP_BINDINGS}.6.#{index}", "#{DHCP_BINDINGS}.7.#{index}")
      return unless agent.integer(status) == 1 && agent.integer(interface) == if_index
      return unless lease.tag_class.application? && lease.tag_number == SNMP::AppTags::Gauge32.value && lease.get_unsigned32 > 0
      return unless agent.integer(address_type) == 1
      if (bytes = agent.octets(address)) && bytes.size == 4
        bytes.join('.')
      end
    end

    private def self.mac(bytes : Bytes) : String?
      return unless bytes.size == 6 && bytes[0].even? && bytes.any? { |byte| byte != 0 }
      bytes.hexstring
    end
  end
end
