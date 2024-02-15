require "placeos-driver"

# Documentation: https://aca.im/driver_docs/Extron/usb_extender_plus.pdf

class Extron::UsbExtenderPlus::Endpoint < PlaceOS::Driver
  generic_name :USB_Device
  descriptive_name "Extron USB Extender Plus Endpoint"
  description "Audio-visual signal distribution device"
  udp_port 6137

  default_settings({
    mac_address: "FF:FF:FF:FF:FF:FF",
    location:    "under_desk",
  })

  @joined_to : Array(String) = [] of String

  def on_load
    queue.delay = 300.milliseconds

    # mac addresses this is connected to
    self[:joined_to] = @joined_to
    on_update
  end

  def on_update
    # Ensure the MAC address is in a consistent format
    self[:mac_address] = setting(String, :mac_address).gsub(/\-|\:/, "").downcase
    self[:ip] = config.ip
    self[:port] = config.port

    # human readable location of the device
    self[:location] = setting(String, :location)

    schedule.clear
    schedule.every(2.minutes) do
      logger.debug { "-- polling extron USB device" }

      # Manually set the connection state (UDP device)
      if query_joins.success?
        set_connected_state(true) unless self[:connected]
      end
    end
  end

  def connected
    query_joins
  end

  def query_joins
    task = send("2f03f4a2000000000300".hexbytes).get
    if !task.state.success?
      set_connected_state(false) if self[:connected]
      logger.warn { "Extron USB Device Probably Offline: #{config.ip}\nJoin query failed." }
    end
    task.state
  end

  def unjoin_all
    unjoins = [] of PlaceOS::Driver::Task

    if @joined_to.empty?
      logger.debug { "nothing to unjoin from" }
    end

    @joined_to.each do |mac|
      unjoins << send_unjoin(mac)
    end

    unjoins.each(&.get)
    query_joins
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
      send_unjoin(mac).get
      query_joins
    else
      logger.debug { "not currently joined to #{from}" }
    end
  end

  def join(mac : String)
    mac = mac.gsub(/\-|\:/, "").downcase
    logger.debug { "joining with #{mac}" }
    send("2f03f4a2020000000302#{mac}".hexbytes, delay: 600.milliseconds).get
    query_joins
  end

  protected def send_unjoin(mac : String)
    logger.debug { "unjoining from #{mac}" }
    send "2f03f4a2020000000303#{mac}".hexbytes, delay: 600.milliseconds
  end

  def received(data, task)
    resp = data.hexstring
    logger.debug { "Extron USB sent: #{resp}" }

    check = resp[0..21]
    if check == "2f03f4a200000000030100" || check == "2f03f4a200000000030101"
      self[:is_host] = check[-1] == '0'

      macs = resp[22..-1].scan(/.{12}/).map(&.to_s)
      logger.debug { "Extron USB joined with: #{macs}" }
      self[:joined_to] = @joined_to = macs
    else
      case resp
      when "2f03f4a2010000000003"
        logger.debug { "Extron USB responded to UDP ping" }
      when "2f03f4a2020000000003"
        logger.debug { "join/unjoin success" }
      when "2f03f4a2020000000308"
        # I think this is what this is.. just a guess
        logger.debug { "join/unjoin might have failed.." }
      else
        logger.info { "Unknown response from extron: #{resp}" }
      end
    end

    task.try &.success
  end
end
