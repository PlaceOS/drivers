require "placeos-driver"
require "./poe_reboot_snmp"

class Networking::PoeReboot < PlaceOS::Driver
  descriptive_name "Network Switch PoE Device Reboot"
  generic_name :PoeReboot
  description "Power cycles devices identified by IP and MAC prefix on managed PoE switches."

  default_settings({
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
    # Optional Catalyst VLAN IDs per switch, e.g. {"192.0.2.1": [10, 20]}.
    # When omitted, use Q-BRIDGE-MIB or discover Catalyst VLANs via CISCO-VTP-MIB.
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

  record PortState, ip : String, mac : String, vlan : Int32?, if_index : Int32, interface_name : String?,
    poe_group : Int32, poe_port : Int32, poe_admin_enabled : Bool?, delivering_power : Bool?,
    skip_reason : String? do
    include JSON::Serializable
  end

  record Match, switch_ip : String, index : PoeRebootSnmp::PoeIndex, location : PoeRebootSnmp::FdbLocation,
    state : PortState

  record RestorePoint, switch_ip : String, if_index : Int32?, index : PoeRebootSnmp::PoeIndex do
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
    switches = configured_ips(:switch_ips)
    devices = configured_ips(:device_ips).to_set
    prefixes = (setting?(Array(String), :mac_prefixes) || [] of String).map do |value|
      prefix = value.strip.gsub(/[:-]/, "").gsub('.', "").downcase
      raise ArgumentError.new("mac_prefixes must contain hexadecimal manufacturer prefixes (6 to 12 digits)") unless prefix.matches?(/\A[0-9a-f]{6,12}\z/)
      prefix
    end
    off_seconds = setting?(Int32, :reboot_off_seconds) || 5
    raise ArgumentError.new("reboot_off_seconds must be positive") unless off_seconds > 0
    vlans = setting?(Hash(String, Array(Int32)), :switch_vlans) || {} of String => Array(Int32)
    vlans.each_value do |ids|
      raise ArgumentError.new("switch_vlans must contain VLAN IDs between 1 and 4094") unless ids.all? { |id| (1..4094).includes?(id) }
    end
    mappings = setting?(Hash(String, Hash(Int32, PoeRebootSnmp::PoeIndex)), :poe_port_mappings) ||
               {} of String => Hash(Int32, PoeRebootSnmp::PoeIndex)
    mappings.each_value do |ports|
      unless ports.all? { |if_index, index| if_index > 0 && index.group > 0 && index.port > 0 }
        raise ArgumentError.new("poe_port_mappings must use positive interface, group and port indices")
      end
    end

    credentials = setting?(PoeRebootSnmp::Credentials, :snmp) || PoeRebootSnmp::Credentials.from_json("{}")
    credentials.validate unless switches.empty?
    neighbors = configured_ips(:neighbor_ips)
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
      discover(options)
    end
  end

  @[Security(Level::Administrator)]
  def reboot : Array(RebootResult)
    with_operation do |options|
      restore_pending(options)
      discovery = discover(options)
      results = [] of RebootResult
      if discovery[:complete] && !restoration_pending?
        discovery[:matches].group_by { |match| {match.switch_ip, match.index} }.each_value do |matches|
          break unless @options == options
          results << cycle_matches(options, matches)
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
    ip = Socket::IPAddress.new(device_ip.strip, 0).address
    manual_reboot do |options|
      discovery = discover(options, Set{ip}, publish: false)
      raise "Discovery incomplete for #{ip}" unless discovery[:complete]
      raise discovery[:unresolved][ip] if discovery[:unresolved].has_key?(ip)

      cycle_matches(options, discovery[:matches])
    end
  end

  # Use an exact IF-MIB interface name or the POWER-ETHERNET-MIB port index
  # and group. The group defaults to 1 for an integer port.
  @[Security(Level::Support)]
  def reboot_port(switch_ip : String, port : Int32 | String, group : Int32 = 1) : RebootResult
    host = Socket::IPAddress.new(switch_ip.strip, 0).address
    manual_reboot do |options|
      raise "Switch #{host} is outside switch_ips" unless options.switches.includes?(host)
      if port.is_a?(Int32)
        raise ArgumentError.new("PoE group and port must be positive") unless group > 0 && port > 0
        cycle(options, host, PoeRebootSnmp::PoeIndex.new(group, port), [] of String)
      else
        index, if_index = named_port(options, host, port.strip)
        cycle(options, host, index, [] of String, if_index: if_index)
      end
    end
  end

  private def named_port(options : Options, host : String, name : String)
    raise ArgumentError.new("Port name is empty") if name.empty?

    with_agent(options, host) do |agent|
      interfaces = [] of Int32
      agent.column(PoeRebootSnmp::IF_NAME) do |index, binding|
        if bytes = agent.octets(binding)
          interfaces << index.to_i if String.new(bytes) == name
        end
      end
      raise "Interface #{name} is unavailable or ambiguous on #{host}" unless interfaces.size == 1

      if_index = interfaces.first
      index = PoeRebootSnmp.poe_ports(agent, configured_mapping(options, host))[if_index]?
      raise "No verified PoE mapping for interface #{name} on #{host}" unless index

      {index, if_index}
    end
  end

  private def configured_ips(key : Symbol)
    (setting?(Array(String), key) || [] of String).map { |ip| Socket::IPAddress.new(ip.strip, 0).address }.uniq
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

  private def discover(options : Options, devices : Set(String) = options.devices, publish = true)
    neighbors = Hash(String, Set(String)).new
    neighbor_errors = Hash(String, String).new
    if !options.switches.empty? && !devices.empty? && !options.prefixes.empty?
      options.neighbors.each do |host|
        with_agent(options, host) { |agent| PoeRebootSnmp.neighbors(agent, devices, neighbors) }
      rescue error
        neighbor_errors[host] = error.message || error.class.name
      end
    end

    targets = Hash(String, Array(String)).new
    unresolved = Hash(String, String).new
    devices.each do |ip|
      addresses = neighbors[ip]?
      if options.prefixes.empty?
        unresolved[ip] = "No MAC manufacturer prefixes configured"
      elsif addresses.nil?
        unresolved[ip] = "IP neighbor entry unavailable"
      elsif addresses.size != 1
        unresolved[ip] = "IP resolves to multiple MAC addresses"
      elsif options.prefixes.none? { |prefix| addresses.first.starts_with?(prefix) }
        unresolved[ip] = "MAC manufacturer prefix did not match"
      else
        (targets[addresses.first] ||= [] of String) << ip
        unresolved[ip] = "No verified PoE port learned this MAC"
      end
    end

    matches = [] of Match
    switch_errors = Hash(String, String).new
    unless targets.empty?
      macs = targets.keys.to_set
      options.switches.each do |host|
        matches.concat(with_agent(options, host) { |agent| switch_matches(options, agent, targets, macs) })
      rescue error
        switch_errors[host] = error.message || error.class.name
      end
    end

    eligible = [] of Match
    ambiguous = Set(String).new
    matches.group_by(&.state.ip).each do |ip, candidates|
      usable = candidates.select { |match| match.state.skip_reason.nil? }
      case usable.size
      when 0
        unresolved[ip] = candidates.map(&.state.skip_reason).compact.uniq.join("; ")
      when 1
        unresolved.delete(ip)
        eligible << usable.first
      else
        unresolved[ip] = "MAC is on multiple powered PoE ports"
        ambiguous << ip
      end
    end

    complete = @options == options && switch_errors.empty? && neighbor_errors.empty?
    result = {matches: eligible, complete: complete, unresolved: unresolved}
    return result unless publish && @options == options

    # Keep every configured switch visible, even when no targets were found.
    by_switch = matches.group_by(&.switch_ip)
    self[:switches] = options.switches.to_h do |host|
      ports = (by_switch[host]? || [] of Match).map do |match|
        state = match.state
        ambiguous.includes?(state.ip) && state.skip_reason.nil? ? state.copy_with(skip_reason: unresolved[state.ip]) : state
      end
      {host, {ports: ports, error: switch_errors[host]?}}
    end
    self[:unresolved_devices] = unresolved
    self[:neighbor_errors] = neighbor_errors
    self[:last_discovery] = Time.utc
    result
  end

  private def switch_matches(options : Options, agent : PoeRebootSnmp::Agent, targets : Hash(String, Array(String)), macs : Set(String))
    fdb = PoeRebootSnmp.forwarding(agent, options.vlans[agent.host]?.try(&.uniq), macs)
    return [] of Match if fdb.locations.empty?

    mapping = PoeRebootSnmp.poe_ports(agent, configured_mapping(options, agent.host))
    matches = [] of Match
    fdb.locations.each do |mac, locations|
      locations.group_by(&.if_index).each do |if_index, rows|
        index = mapping[if_index]?
        next unless index
        name, admin, detection, mode, trunk = agent.read(
          "#{PoeRebootSnmp::IF_NAME}.#{if_index}", "#{PoeRebootSnmp::PSE_ADMIN}.#{index}",
          "#{PoeRebootSnmp::PSE_DETECTION}.#{index}", "#{PoeRebootSnmp::CISCO_PSE_MODE}.#{index}",
          "#{PoeRebootSnmp::CISCO_TRUNK}.#{if_index}")
        enabled = agent.integer(admin).try { |value| value == PoeRebootSnmp::ENABLED }
        delivering = agent.integer(detection).try { |value| value == PoeRebootSnmp::DELIVERING }
        reason = port_issue(enabled, delivering, agent.integer(mode), agent.integer(trunk))
        reason ||= "Multiple MAC addresses learned on this interface" if fdb.shared.includes?(if_index)
        vlans = rows.map(&.vlan).uniq
        targets[mac].each do |ip|
          state = PortState.new(ip, mac.scan(/../).join(':', &.[0]), vlans.size == 1 ? vlans.first : nil,
            if_index, agent.octets(name).try { |bytes| String.new(bytes).presence }, index.group, index.port,
            enabled, delivering, reason)
          matches << Match.new(agent.host, index, rows.first, state)
        end
      end
    end
    matches
  end

  private def port_issue(enabled, delivering, mode, trunk) : String?
    return "Interface is a VLAN trunk" if trunk == 1
    return "PoE is disabled or unavailable" unless enabled
    return "PoE is not delivering power" unless delivering
    # Cisco's standard SET false changes its vendor-specific mode to disable.
    return "Cisco PoE mode is not auto" if mode && mode != 1
  end

  private def cycle_matches(options : Options, matches : Array(Match)) : RebootResult
    match = matches.first
    cycle(options, match.switch_ip, match.index, matches.map(&.state.ip), match.location)
  end

  private def cycle(options : Options, host : String, index : PoeRebootSnmp::PoeIndex, ips : Array(String),
                    location : PoeRebootSnmp::FdbLocation? = nil, if_index : Int32? = location.try(&.if_index)) : RebootResult
    with_agent(options, host) do |agent|
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
      if if_index && PoeRebootSnmp.poe_ports(agent, configured_mapping(options, host))[if_index]? != index
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

      self[:pending_restore] = RestorePoint.new(host, if_index, index)
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
    RebootResult.new(ips, host, index.group, index.port, "rebooted", nil)
  rescue error
    failure = error.message || error.class.name
    outcome = restoration_pending? ? "restore_pending" : "failed"
    logger.error(exception: error) { "PoE reboot #{outcome} for #{ips} on #{host}, port #{index}" }
    RebootResult.new(ips, host, index.group, index.port, outcome, failure)
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
    unless options.switches.includes?(pending.switch_ip)
      raise "switch #{pending.switch_ip} is no longer configured"
    end
    with_agent(options, pending.switch_ip) do |agent|
      if_index = pending.if_index
      if if_index && PoeRebootSnmp.poe_ports(agent, configured_mapping(options, pending.switch_ip))[if_index]? != pending.index
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

  private def configured_mapping(options : Options, host : String)
    options.mappings[host]? || {} of Int32 => PoeRebootSnmp::PoeIndex
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
