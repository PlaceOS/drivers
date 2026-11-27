require "placeos-driver"
require "dns"
require "./poe_reboot_snmp"

class Networking::PoeReboot < PlaceOS::Driver
  descriptive_name "Network Switch PoE Device Reboot"
  generic_name :PoeReboot
  description "Power cycles devices identified by IP and MAC prefix on managed PoE switches."

  default_settings({
    # Address lists and per-switch setting keys accept IP literals and DNS names.
    switch_ips:   [] of String,
    device_ips:   [] of String,
    mac_prefixes: [] of String,
    # Optional SNMP sources for neighbor tables, e.g. the target VLANs' gateways.
    # When empty, the driver reads neighbors from switch_ips.
    neighbor_ips: [] of String,
    snmp:         {version: "v2c", community: ""},
    # For v3, use username, auth_protocol/auth_password and priv_protocol/priv_password.
    # On Catalyst, allow BRIDGE-MIB reads in the VLAN contexts. The only write
    # access the driver needs is POWER-ETHERNET-MIB::pethPsePortAdminEnable.
    # snmp.port and snmp.timeout (seconds) default to 161 and 3.
    # Optional VLAN IDs per switch, e.g. {"192.0.2.1": [10, 20]}.
    # Use Q-BRIDGE-MIB or the Catalyst VLAN contexts to find their ports.
    switch_vlans: {} of String => Array(Int32),
    # Optional verified ifIndex -> PoE group/port per switch, e.g.
    # {"192.0.2.1": {"10104": {"group": 1, "port": 4}}}.
    poe_port_mappings:  {} of String => Hash(Int32, PoeRebootSnmp::PoeIndex),
    reboot_off_seconds: 5,
    # Remove the leading underscores to enable an automatic reboot schedule.
    _reboot_cron:     "0 3 * * 0",
    _reboot_timezone: "Australia/Sydney",
  })

  record Options, switches : Array(String), devices : Set(String), prefixes : Array(String),
    neighbors : Array(String), credentials : PoeRebootSnmp::Credentials, off_time : Time::Span,
    vlans : Hash(String, Array(Int32)), mappings : Hash(String, Hash(Int32, PoeRebootSnmp::PoeIndex))

  record SwitchEndpoint, name : String, ip : String

  # Keep DNS answers consistent across the discovery, SETs and recovery journal
  # for one operation. The next operation can pick up changes in DNS.
  class AddressResolution
    @lookups = Hash(Tuple(String, DNS::RecordType), Array(String)).new

    def self.normalize(address : String) : String
      value = address.strip
      raise ArgumentError.new("Network address is empty") if value.empty?
      return Socket::IPAddress.new(value, 0).address if Socket::IPAddress.valid?(value)
      value.downcase
    end

    def device_addresses(address : String) : Array(String)
      return [address] if Socket::IPAddress.valid?(address)
      ips = lookup(address, :a) + lookup(address, :aaaa)
      raise Socket::Error.new("Could not resolve DNS name #{address}") if ips.empty?
      ips
    end

    def endpoint(address : String) : String
      return address if Socket::IPAddress.valid?(address)

      # Prefer IPv4 for dual-stack names. Each name should have one management
      # address per family because the DNS cache stores one answer per type.
      ips = lookup(address, :a)
      ips = lookup(address, :aaaa) if ips.empty?
      raise Socket::Error.new("Could not resolve DNS name #{address}") if ips.empty?
      raise Socket::Error.new("DNS name #{address} has multiple management addresses") if ips.size > 1
      ips.first
    end

    def endpoint?(address : String) : String?
      endpoint(address)
    rescue Socket::Error
      nil
    end

    def matches?(address : String, ip : String) : Bool
      return address == ip if Socket::IPAddress.valid?(address)
      record_type = Socket::IPAddress.valid_v4?(ip) ? DNS::RecordType::A : DNS::RecordType::AAAA
      lookup(address, record_type) == [ip]
    end

    private def lookup(address : String, record_type : DNS::RecordType)
      @lookups[{address, record_type}] ||= begin
        DNS.query(address, {record_type}).compact_map do |record|
          record.ip_address.address if record.type == record_type.value
        end.uniq
      rescue DNS::Packet::Error | IO::TimeoutError | Socket::Error
        [] of String
      end
    end
  end

  record PortState, ip : String, mac : String, vlan : Int32?, if_index : Int32, interface_name : String?,
    poe_group : Int32, poe_port : Int32, poe_admin_enabled : Bool?, delivering_power : Bool?,
    skip_reason : String? do
    include JSON::Serializable
  end

  record Match, switch : SwitchEndpoint, index : PoeRebootSnmp::PoeIndex, location : PoeRebootSnmp::FdbLocation,
    state : PortState

  record RestorePoint, switch_ip : String, if_index : Int32?, index : PoeRebootSnmp::PoeIndex, switch_name : String? = nil do
    include JSON::Serializable
  end

  record RebootResult, ips : Array(String), switch_ip : String, poe_group : Int32, poe_port : Int32,
    outcome : String, error : String? do
    include JSON::Serializable
  end

  @options : Options? = nil
  @running = false

  def on_update
    # A sweep keeps its original settings for restoration. A settings change
    # prevents it from starting another power cycle under those settings.
    @options = nil
    schedule.clear
    self[:configuration_error] = nil
    switches = configured_addresses(:switch_ips)
    devices = configured_addresses(:device_ips).to_set
    prefixes = (setting?(Array(String), :mac_prefixes) || [] of String).map do |value|
      prefix = value.strip.gsub(/[:-]/, "").gsub('.', "").downcase
      raise ArgumentError.new("mac_prefixes must contain hexadecimal manufacturer prefixes (6 to 12 digits)") unless prefix.matches?(/\A[0-9a-f]{6,12}\z/)
      prefix
    end
    off_seconds = setting?(Int32, :reboot_off_seconds) || 5
    raise ArgumentError.new("reboot_off_seconds must be positive") unless off_seconds > 0
    vlans = setting?(Hash(String, Array(Int32)), :switch_vlans) || {} of String => Array(Int32)
    vlans = normalize_keys(vlans)
    vlans.each_value do |ids|
      raise ArgumentError.new("switch_vlans must contain VLAN IDs between 1 and 4094") unless ids.all? { |id| (1..4094).includes?(id) }
    end
    mappings = setting?(Hash(String, Hash(Int32, PoeRebootSnmp::PoeIndex)), :poe_port_mappings) ||
               {} of String => Hash(Int32, PoeRebootSnmp::PoeIndex)
    mappings = normalize_keys(mappings)
    mappings.each_value do |ports|
      unless ports.all? { |if_index, index| if_index > 0 && index.group > 0 && index.port > 0 }
        raise ArgumentError.new("poe_port_mappings must use positive interface, group and port indices")
      end
    end

    credentials = setting?(PoeRebootSnmp::Credentials, :snmp) || PoeRebootSnmp::Credentials.from_json("{}")
    credentials.validate unless switches.empty?
    neighbors = configured_addresses(:neighbor_ips)
    neighbors = switches if neighbors.empty?
    options = Options.new(switches, devices, prefixes, neighbors, credentials, off_seconds.seconds, vlans, mappings)
    @options = options
    schedule.in(0.seconds) { query_state }
    schedule.every(1.hour) { query_state }
    schedule.every(5.minutes) { retry_pending_restore }
    schedule_reboot
  rescue error
    self[:configuration_error] = error.message
    logger.error(exception: error) { "invalid PoE reboot settings" }
  end

  def query_state : Nil
    return if @running || @options.nil?

    with_operation do |options|
      restore_pending(options)
      discover(options, AddressResolution.new)
    end
  end

  @[Security(Level::Administrator)]
  def reboot : Array(RebootResult)
    with_operation do |options|
      restore_pending(options)
      resolution = AddressResolution.new
      discovery = discover(options, resolution)
      results = [] of RebootResult
      if discovery[:complete] && !restoration_pending?
        discovery[:matches].group_by { |match| {match.switch.ip, match.index} }.each_value do |matches|
          break unless @options == options
          results << cycle_matches(options, resolution, matches)
          break if restoration_pending?
        end
      end
      record_reboot(results, discovery[:complete] ? nil : "Discovery incomplete")
      results
    end
  end

  # Resolve a device on the configured switches using the configured MAC prefixes.
  @[Security(Level::Support)]
  def reboot_device(device_ip : String) : RebootResult
    address = AddressResolution.normalize(device_ip)
    manual_reboot do |options|
      resolution = AddressResolution.new
      discovery = discover(options, resolution, Set{address}, publish: false)
      raise "Discovery incomplete for #{address}" unless discovery[:complete]
      raise discovery[:unresolved][address] if discovery[:unresolved].has_key?(address)

      cycle_matches(options, resolution, discovery[:matches])
    end
  end

  # Use an exact IF-MIB interface name or the POWER-ETHERNET-MIB port index
  # and group. The group defaults to 1 for an integer port.
  @[Security(Level::Support)]
  def reboot_port(switch_ip : String, port : Int32 | String, group : Int32 = 1) : RebootResult
    address = AddressResolution.normalize(switch_ip)
    manual_reboot do |options|
      resolution = AddressResolution.new
      switch = configured_switch(options, resolution, address)

      if port.is_a?(Int32)
        raise ArgumentError.new("PoE group and port must be positive") unless group > 0 && port > 0
        cycle(options, resolution, switch, PoeRebootSnmp::PoeIndex.new(group, port), [] of String)
      else
        index, if_index = named_port(options, resolution, switch, port.strip)
        cycle(options, resolution, switch, index, [] of String, if_index: if_index)
      end
    end
  end

  private def configured_switch(options : Options, resolution : AddressResolution, address : String) : SwitchEndpoint
    if options.switches.includes?(address)
      return SwitchEndpoint.new(address, resolution.endpoint(address))
    end

    matches = options.switches.compact_map do |name|
      ip = resolution.endpoint?(name)
      SwitchEndpoint.new(name, ip) if ip && resolution.matches?(address, ip)
    end.uniq(&.ip)
    raise "Switch #{address} matches multiple configured switches" if matches.size > 1
    matches.first? || raise "Switch #{address} is outside switch_ips"
  end

  private def named_port(options : Options, resolution : AddressResolution, switch : SwitchEndpoint, name : String)
    raise ArgumentError.new("Port name is empty") if name.empty?

    with_agent(options, switch.ip) do |agent|
      interfaces = [] of Int32
      agent.column(PoeRebootSnmp::IF_NAME) do |index, binding|
        if bytes = agent.octets(binding)
          interfaces << index.to_i if String.new(bytes) == name
        end
      end
      raise "Interface #{name} is unavailable or ambiguous on #{switch.name}" unless interfaces.size == 1

      if_index = interfaces.first
      index = PoeRebootSnmp.poe_ports(agent, configured_mapping(options, resolution, switch))[if_index]?
      raise "No verified PoE mapping for interface #{name} on #{switch.name}" unless index

      {index, if_index}
    end
  end

  private def configured_addresses(key : Symbol)
    (setting?(Array(String), key) || [] of String).map { |address| AddressResolution.normalize(address) }.uniq
  end

  private def normalize_keys(settings : Hash(String, T)) : Hash(String, T) forall T
    normalized = Hash(String, T).new
    settings.each do |address, value|
      key = AddressResolution.normalize(address)
      if normalized.has_key?(key) && normalized[key] != value
        raise ArgumentError.new("Conflicting switch settings for #{key}")
      end
      normalized[key] = value
    end
    normalized
  end

  private def schedule_reboot
    cron = setting?(String, :reboot_cron).presence
    return unless cron
    timezone = setting?(String, :reboot_timezone).presence || "Australia/Sydney"
    schedule.cron(cron, Time::Location.load(timezone)) { reboot }
  rescue error
    self[:configuration_error] = "Invalid reboot_cron or reboot_timezone"
    logger.error(exception: error) { "invalid PoE reboot schedule" }
  end

  private def with_operation(&)
    options = @options || raise "PoE reboot configuration is invalid"
    raise "PoE discovery or reboot is already running" if @running

    @running = true
    begin
      yield options
    ensure
      @running = false
      schedule.in(0.seconds) { query_state } if @options && @options != options && !terminated?
    end
  end

  private def manual_reboot(&)
    with_operation do |options|
      raise "Power restoration pending" if restoration_pending?
      result = yield options
      record_reboot([result])
      result
    end
  end

  private def record_reboot(results : Array(RebootResult), blocked : String? = nil)
    blocked ||= "Power restoration pending" if restoration_pending?
    self[:last_reboot] = {time: Time.utc, results: results, blocked: blocked}
  end

  private def discover(options : Options, resolution : AddressResolution, devices : Set(String) = options.devices, publish = true)
    switch_addresses = Hash(String, String).new
    switch_errors = Hash(String, String).new
    options.switches.each do |name|
      switch_addresses[name] = resolution.endpoint(name)
    rescue error : Socket::Error
      switch_errors[name] = error.message || error.class.name
    end

    device_addresses = Hash(String, Array(String)).new
    unresolved = Hash(String, String).new
    devices.each do |name|
      device_addresses[name] = resolution.device_addresses(name)
    rescue error : Socket::Error
      unresolved[name] = error.message || error.class.name
    end

    neighbors = Hash(String, Set(String)).new
    neighbor_errors = Hash(String, String).new
    if !switch_addresses.empty? && !device_addresses.empty? && !options.prefixes.empty?
      ips = device_addresses.values.flatten.to_set
      polled = Set(String).new
      options.neighbors.each do |name|
        ip = resolution.endpoint(name)
        next unless polled.add?(ip)
        with_agent(options, ip) { |agent| PoeRebootSnmp.neighbors(agent, ips, neighbors) }
      rescue error
        neighbor_errors[name] = error.message || error.class.name
      end
    end

    targets = Hash(String, Set(String)).new
    matched_addresses = Hash(String, Array(String)).new
    device_addresses.each do |name, ips|
      macs = ips.flat_map { |ip| neighbors[ip]?.try(&.to_a) || [] of String }.uniq
      if options.prefixes.empty?
        unresolved[name] = "No MAC manufacturer prefixes configured"
      elsif macs.empty?
        unresolved[name] = "IP neighbor entry unavailable"
      elsif macs.size != 1
        unresolved[name] = "IP resolves to multiple MAC addresses"
      elsif options.prefixes.none? { |prefix| macs.first.starts_with?(prefix) }
        unresolved[name] = "MAC manufacturer prefix did not match"
      else
        matched_ips = ips.select { |ip| neighbors.has_key?(ip) }
        (targets[macs.first] ||= Set(String).new).concat(matched_ips)
        matched_addresses[name] = matched_ips
        unresolved[name] = "No learned forwarding entry for MAC #{format_mac(macs.first)}"
      end
    end

    matches = [] of Match
    forwarding_issues = Hash(String, Set(String)).new
    unless targets.empty?
      macs = targets.keys.to_set
      switch_addresses.to_a.uniq(&.last).each do |name, ip|
        switch = SwitchEndpoint.new(name, ip)
        found, issues = with_agent(options, ip) { |agent| switch_matches(options, resolution, switch, agent, targets, macs) }
        matches.concat(found)
        issues.each do |mac, reasons|
          targets[mac].each do |target_ip|
            entries = forwarding_issues[target_ip] ||= Set(String).new
            reasons.each { |reason| entries << "#{name}: #{reason}" }
          end
        end
      rescue error
        switch_errors[ip] = error.message || error.class.name
      end
    end

    eligible = Set(Match).new
    ambiguous = Set(String).new
    by_device = matches.group_by(&.state.ip)
    matched_addresses.each do |name, ips|
      candidates = ips.flat_map { |ip| by_device[ip]? || [] of Match }
      if candidates.empty?
        reasons = ips.flat_map { |ip| forwarding_issues[ip]?.try(&.to_a) || [] of String }
        unresolved[name] = reasons.uniq.join("; ") unless reasons.empty?
        next
      end

      usable = candidates.select { |match| match.state.skip_reason.nil? }
      case usable.uniq { |match| {match.switch.ip, match.index} }.size
      when 0
        unresolved[name] = candidates.map(&.state.skip_reason).compact.uniq.join("; ")
      when 1
        unresolved.delete(name)
        eligible.concat(usable)
      else
        unresolved[name] = "MAC is on multiple powered PoE ports"
        ambiguous.concat(ips)
      end
    end

    complete = @options == options && switch_errors.empty? && neighbor_errors.empty?
    result = {matches: eligible.to_a, complete: complete, unresolved: unresolved}
    return result unless publish && @options == options

    # Use the configured address as the stable key and report the IP in use.
    by_switch = matches.group_by(&.switch.ip)
    self[:switches] = options.switches.to_h do |name|
      ip = switch_addresses[name]?
      ports = (ip.try { |address| by_switch[address]? } || [] of Match).map do |match|
        state = match.state
        ambiguous.includes?(state.ip) && state.skip_reason.nil? ? state.copy_with(skip_reason: "MAC is on multiple powered PoE ports") : state
      end
      {name, {ip: ip, ports: ports, error: switch_errors[name]? || ip.try { |address| switch_errors[address]? }}}
    end
    self[:unresolved_devices] = unresolved
    self[:neighbor_errors] = neighbor_errors
    self[:last_discovery] = Time.utc
    result
  end

  private def switch_matches(options : Options, resolution : AddressResolution, switch : SwitchEndpoint,
                             agent : PoeRebootSnmp::Agent, targets : Hash(String, Set(String)), macs : Set(String))
    vlans = switch_setting(options.vlans, resolution, switch)
    fdb = PoeRebootSnmp.forwarding(agent, vlans.try(&.uniq), macs)
    return {[] of Match, fdb.issues} if fdb.locations.empty?

    mapping = PoeRebootSnmp.poe_ports(agent, configured_mapping(options, resolution, switch))
    matches = [] of Match
    fdb.locations.each do |mac, locations|
      mac_address = format_mac(mac)
      locations.group_by(&.if_index).each do |if_index, rows|
        port_vlans = rows.map(&.vlan).uniq
        vlan = port_vlans.size == 1 ? port_vlans.first : nil
        name_oid = "#{PoeRebootSnmp::IF_NAME}.#{if_index}"
        index = mapping[if_index]?
        unless index
          interface = agent.octets(agent.read(name_oid).first).try { |bytes| String.new(bytes).presence }
          port = interface ? "#{interface} (ifIndex #{if_index})" : "ifIndex #{if_index}"
          fdb.add_issue(mac, vlan, "for MAC #{mac_address} identifies #{port}, which has no verified PoE mapping")
          next
        end
        name, admin, detection, mode, trunk = agent.read(
          name_oid, "#{PoeRebootSnmp::PSE_ADMIN}.#{index}",
          "#{PoeRebootSnmp::PSE_DETECTION}.#{index}", "#{PoeRebootSnmp::CISCO_PSE_MODE}.#{index}",
          "#{PoeRebootSnmp::CISCO_TRUNK}.#{if_index}")
        enabled = agent.integer(admin).try { |value| value == PoeRebootSnmp::ENABLED }
        delivering = agent.integer(detection).try { |value| value == PoeRebootSnmp::DELIVERING }
        reason = port_issue(enabled, delivering, agent.integer(mode), agent.integer(trunk))
        reason ||= "Multiple MAC addresses learned on this interface" if fdb.shared.includes?(if_index)
        targets[mac].each do |ip|
          state = PortState.new(ip, mac_address, vlan,
            if_index, agent.octets(name).try { |bytes| String.new(bytes).presence }, index.group, index.port,
            enabled, delivering, reason)
          matches << Match.new(switch, index, rows.first, state)
        end
      end
    end
    {matches, fdb.issues}
  end

  private def format_mac(mac : String) : String
    mac.scan(/../).join(':', &.[0])
  end

  private def port_issue(enabled, delivering, mode, trunk) : String?
    return "Interface is a VLAN trunk" if trunk == 1
    return "PoE is disabled or unavailable" unless enabled
    return "PoE is not delivering power" unless delivering
    # Cisco's standard SET false changes its vendor-specific mode to disable.
    return "Cisco PoE mode is not auto" if mode && mode != 1
  end

  private def cycle_matches(options : Options, resolution : AddressResolution, matches : Array(Match)) : RebootResult
    match = matches.first
    cycle(options, resolution, match.switch, match.index, matches.map(&.state.ip), match.location)
  end

  private def cycle(options : Options, resolution : AddressResolution, switch : SwitchEndpoint,
                    index : PoeRebootSnmp::PoeIndex, ips : Array(String), location : PoeRebootSnmp::FdbLocation? = nil,
                    if_index : Int32? = location.try(&.if_index)) : RebootResult
    with_agent(options, switch.ip) do |agent|
      if location
        agent.in_vlan(location.context_vlan) do |scoped|
          port, status, interface = scoped.read(location.port_oid, location.status_oid,
            "#{PoeRebootSnmp::BRIDGE_IFINDEX}.#{location.bridge_port}")
          unless scoped.integer(port) == location.bridge_port && scoped.integer(status) == PoeRebootSnmp::LEARNED &&
                 scoped.integer(interface) == location.if_index
            raise "learned MAC location changed before reboot"
          end
        end
      end
      if if_index && PoeRebootSnmp.poe_ports(agent, configured_mapping(options, resolution, switch))[if_index]? != index
        raise "PoE port mapping changed before reboot"
      end

      admin_oid = "#{PoeRebootSnmp::PSE_ADMIN}.#{index}"
      admin, detection, mode = agent.read(admin_oid, "#{PoeRebootSnmp::PSE_DETECTION}.#{index}",
        "#{PoeRebootSnmp::CISCO_PSE_MODE}.#{index}")
      if location
        trunk = agent.integer(agent.read("#{PoeRebootSnmp::CISCO_TRUNK}.#{location.if_index}").first)
      end
      if reason = port_issue(agent.integer(admin) == PoeRebootSnmp::ENABLED,
           agent.integer(detection) == PoeRebootSnmp::DELIVERING, agent.integer(mode), trunk)
        raise reason
      end
      raise "settings changed before reboot" unless @options == options

      self[:pending_restore] = RestorePoint.new(switch.ip, if_index, index, switch.name)
      if @options != options
        self[:pending_restore] = nil
        raise "settings changed before reboot"
      end
      begin
        agent.write_integer(admin_oid, PoeRebootSnmp::DISABLED)
        unless agent.integer(agent.read(admin_oid).first) == PoeRebootSnmp::DISABLED
          raise "PoE disable could not be verified"
        end
        sleep options.off_time
      ensure
        # Even an unacknowledged SET can have turned power off.
        restore_power(agent, admin_oid)
        self[:pending_restore] = nil
      end
    end
    RebootResult.new(ips, switch.ip, index.group, index.port, "rebooted", nil)
  rescue error
    failure = error.message || error.class.name
    outcome = restoration_pending? ? "restore_pending" : "failed"
    logger.error(exception: error) { "PoE reboot #{outcome} for #{ips} on #{switch.name}, port #{index}" }
    RebootResult.new(ips, switch.ip, index.group, index.port, outcome, failure)
  end

  private def restoration_pending?
    !self[:pending_restore]?.try(&.raw).nil?
  end

  private def retry_pending_restore
    return unless restoration_pending?
    return if @running || @options.nil?

    with_operation { |options| restore_pending(options) }
  end

  private def restore_pending(options : Options)
    pending = status?(RestorePoint?, :pending_restore)
    return unless pending
    resolution = AddressResolution.new
    name = pending.switch_name || pending.switch_ip
    unless options.switches.includes?(name)
      name = options.switches.find { |configured| resolution.matches?(configured, pending.switch_ip) }
      raise "switch #{pending.switch_ip} is no longer configured" unless name
    end
    switch = SwitchEndpoint.new(name, pending.switch_ip)
    with_agent(options, switch.ip) do |agent|
      if_index = pending.if_index
      if if_index && PoeRebootSnmp.poe_ports(agent, configured_mapping(options, resolution, switch))[if_index]? != pending.index
        raise "PoE mapping changed for #{pending.switch_ip} interface #{if_index}"
      end
      oid = "#{PoeRebootSnmp::PSE_ADMIN}.#{pending.index}"
      case agent.integer(agent.read(oid).first)
      when PoeRebootSnmp::DISABLED
        restore_power(agent, oid)
      when PoeRebootSnmp::ENABLED
        # The earlier restore succeeded.
      else
        raise "PoE administrative state unavailable for #{pending.switch_ip} port #{pending.index}"
      end
      self[:pending_restore] = nil
    end
  rescue error
    logger.error(exception: error) { "could not restore PoE from pending reboot" }
  end

  private def restore_power(agent : PoeRebootSnmp::Agent, oid : String)
    failure = nil
    3.times do
      begin
        agent.write_integer(oid, PoeRebootSnmp::ENABLED)
      rescue error
        failure = error
      end

      begin
        return if agent.integer(agent.read(oid).first) == PoeRebootSnmp::ENABLED
      rescue error
        failure = error
      end
    end
    raise SNMP::Error.new("could not verify restored PoE on #{agent.host}, #{oid}", cause: failure)
  end

  private def switch_setting(settings : Hash(String, T), resolution : AddressResolution, switch : SwitchEndpoint) : T? forall T
    values = settings.compact_map do |address, value|
      value if address == switch.name || resolution.matches?(address, switch.ip)
    end.uniq
    raise ArgumentError.new("Conflicting switch settings for #{switch.name}") if values.size > 1
    values.first?
  end

  private def configured_mapping(options : Options, resolution : AddressResolution, switch : SwitchEndpoint)
    switch_setting(options.mappings, resolution, switch) || {} of Int32 => PoeRebootSnmp::PoeIndex
  end

  private def with_agent(options : Options, host : String, &)
    agent = options.credentials.agent(host)
    begin
      yield agent
    ensure
      agent.close
    end
  end
end
