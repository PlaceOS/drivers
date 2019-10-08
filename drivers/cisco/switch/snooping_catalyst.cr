module Cisco; end
module Cisco::Switch; end

require "set"

class Cisco::Switch::SnoopingCatalyst < ACAEngine::Driver
  # Discovery Information
  descriptive_name "Cisco Catalyst Switch IP Snooping"
  generic_name :Snooping
  tcp_port 22

  # Communication settings
  # tokenize delimiter: /\n|-- /

  default_settings({
    ssh: {
      username: :cisco,
      password: :cisco
    },
    building: "building_code",
    ignore_macs: {
      "Cisco Phone Dock" => "7001b5"
    }
  })

  # Interfaces that indicate they have a device connected
  @check_interface = ::Set(String).new

  # MAC, IP, Interface
  @snooping = [] of Tuple(String, String, String)

  # interface to MAC address mappings
  @interface_macs = {} of String => String
  @devices = {} of String => NamedTuple(mac: String, ip: String)

  @hostname : String? = nil
  @switch_name : String? = nil
  @ignore_macs = ::Set(String).new

  def on_load
    # TODO:: need to detect "--More--" which may not have a newline
    transport.tokenizer = Tokenizer.new("\n")

    on_update
  end

  def on_update
    @ignore_macs = ::Set.new((setting?(Hash(String, String), :ignore_macs) || {} of String => String).values)

    self[:name] = @switch_name = setting?(String, :switch_name)
    self[:ip_address] = config.ip.not_nil!.downcase
    self[:building] = setting?(String, :building)
    self[:level] = setting?(String, :level)
    self[:last_successful_query] ||= 0
  end

  def connected
    schedule.in(1.second) { query_connected_devices }
    schedule.every(1.minute) { query_connected_devices }
  end

  def disconnected
    schedule.clear
    queue.clear
  end

  # Don't want the every day user using this method
  @[ACAEngine::Driver::Security(Level::Administrator)]
  def run(command : String)
    do_send command
  end

  def query_interface_status
    do_send "show interfaces status"
  end

  def query_mac_addresses
    @interface_macs.clear
    do_send "show mac address-table"
  end

  def query_snooping_bindings
    @snooping.clear
    do_send "show ip dhcp snooping binding"
  end

  @querying_devices : Bool = false

  def query_connected_devices
    return if @querying_devices
    @querying_devices = true

    logger.debug { "Querying for connected devices" }

    query_interface_status.get
    sleep 3.seconds

    query_mac_addresses.get
    sleep 3.seconds

    query_snooping_bindings.get
    sleep 2.seconds

    nil
  ensure
    @querying_devices = false
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Switch sent: #{data}" }

    # determine the hostname
    if @hostname.nil?
      parts = data.split(">")
      if parts.size == 2
        self[:hostname] = @hostname = parts[0]

        # Exit early as this line is not a response
        return task.try &.success
      end
    end

    # Detect more data available
    # ==> --More--
    if data =~ /More/
      send(" ", priority: 99, retries: 0)
      return task.try &.success
    end

    # Interface MAC Address detection
    # 33    e4b9.7aa5.aa7f    STATIC      Gi3/0/8
    # 10    f4db.e618.10a4    DYNAMIC     Te2/0/40
    if data =~ /STATIC|DYNAMIC/
      parts = data.split(/\s+/).reject(&.empty?)
      mac = format(parts[1])
      interface = normalise(parts[-1])

      @interface_macs[interface] = mac if mac && interface

      return :success
    end

    # Interface change detection
    # 07-Aug-2014 17:28:26 %LINK-I-Up:  gi2
    # 07-Aug-2014 17:28:31 %STP-W-PORTSTATUS: gi2: STP status Forwarding
    # 07-Aug-2014 17:44:43 %LINK-I-Up:  gi2, aggregated (1)
    # 07-Aug-2014 17:44:47 %STP-W-PORTSTATUS: gi2: STP status Forwarding, aggregated (1)
    # 07-Aug-2014 17:45:24 %LINK-W-Down:  gi2, aggregated (2)
    if data =~ /%LINK/
      interface = normalise(data.split(",")[0].split(/\s/)[-1])

      if data =~ /Up:/
        logger.debug { "Notify Up: #{interface}" }
        @check_interface << interface

        # Delay here is to give the PC some time to negotiate an IP address
        # schedule.in(3000) { query_snooping_bindings }
      elsif data =~ /Down:/
        logger.debug { "Notify Down: #{interface}" }
        # We are no longer interested in this interface
        @check_interface.delete(interface)
      end

      self[:interfaces] = @check_interface

      return task.try &.success
    end

    if data.starts_with?("Total number")
      logger.debug { "Processing #{@snooping.size} bindings" }
      checked = Set(String).new
      devices = {} of String => NamedTuple(mac: String, ip: String)
      state_changed = false

      @snooping.each do |mac, ip, interface|
        next unless @check_interface.includes?(interface)
        next unless @interface_macs[interface]? == mac
        next if checked.includes?(interface)

        checked << interface
        iface = @devices[interface]? || {mac: "", ip: ""}

        if iface[:ip] != ip || iface[:mac] != mac
          logger.debug { "New connection on #{interface} with #{ip}: #{mac}" }
          devices[interface] = {mac: mac, ip: ip}
          state_changed = true
        else
          devices[interface] = iface
        end
      end

      # did an interface change state
      if state_changed
        @devices = devices
        self[:devices] = devices
      end

      # As a link up or down might have modified this list
      if @check_interface != checked
        @check_interface = checked
        self[:interfaces] = checked
      end

      self[:last_successful_query] = Time.utc.to_unix

      return task.try &.success
    end

    # Grab the parts of the response
    entries = data.split(/\s+/).reject(&.empty?)

    # show interfaces status
    # Port  Name         Status     Vlan     Duplex  Speed Type
    # Gi1/1            notconnect   1      auto   auto No Gbic
    # Fa6/1            connected  1      a-full  a-100 10/100BaseTX
    if entries.includes?("connected")
      interface = entries[0].downcase
      return task.try &.success if @check_interface.includes? interface

      logger.debug { "Interface Up: #{interface}" }
      @check_interface << interface

      return task.try &.success
    elsif entries.includes?("notconnect")
      interface = entries[0].downcase
      return task.try &.success unless @check_interface.includes? interface

      # Delete the lookup records
      logger.debug { "Interface Down: #{interface}" }
      @check_interface.delete(interface)

      return task.try &.success
    end

    # We are looking for MAC to IP address mappings
    # =============================================
    # MacAddress      IpAddress    Lease(sec)  Type       VLAN  Interface
    # ------------------  ---------------  ----------  -------------  ----  --------------------
    # 00:21:CC:D5:33:F4   10.151.130.1   16283     dhcp-snooping   113   GigabitEthernet3/0/43
    # Total number of bindings: 3
    if entries.size > 2
      interface = normalise(entries[-1])

      # We only want entries that are currently active
      if @check_interface.includes? interface

        # Ensure the data is valid
        mac = entries[0]
        if mac =~ /^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$/
          mac = format(mac)
          ip = entries[1]

          @snooping << {mac, ip, interface} unless @ignore_macs.includes?(mac[0..5])
        end
      end
    end

    task.try &.success
  end

  protected def do_send(cmd, **options)
    logger.debug { "requesting: #{cmd}" }
    send("#{cmd}\n", **options)
  end

  protected def format(mac)
    mac.gsub(/(0x|[^0-9A-Fa-f])*/, "").downcase
  end

  protected def normalise(interface)
    # Port-channel == po
    interface.downcase.gsub("tengigabitethernet", "te").gsub("twogigabitethernet", "tw").gsub("gigabitethernet", "gi").gsub("fastethernet", "fa")
  end
end
