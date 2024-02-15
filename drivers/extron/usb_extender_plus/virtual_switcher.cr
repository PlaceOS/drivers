require "placeos-driver"
require "placeos-driver/interface/switchable"

# A USB Device (webcam, keyboard, etc) can only connect to a single Host (computer) at a time.
#  --> the USB Hosts are the inputs of this switcher
#  --> the devices are the outputs.
# This is because a host can connect to multiple devices

class Extron::UsbExtenderPlus::VirtualSwitcher < PlaceOS::Driver
  include PlaceOS::Driver::Interface::Switchable(Int32, Int32)

  generic_name :USB_Switcher
  descriptive_name "Extron USB Extender Plus Switcher"

  accessor hosts : Array(USB_Host)
  accessor devices : Array(USB_Device)

  getter host_macs : Hash(String, Int32) do
    hash = {} of String => Int32
    hosts.each_with_index do |host, index|
      hash[host.status(String, :mac_address)] = index
    end
    hash
  end

  getter device_macs : Hash(String, Int32) do
    hash = {} of String => Int32
    devices.each_with_index do |device, index|
      hash[device.status(String, :mac_address)] = index
    end
    hash
  end

  # lazily obtain host and device mac addresses
  def on_update
    @host_macs = nil
    @device_macs = nil
  end

  # 0 == unjoin, input is the host index
  def switch_to(input : Int32)
    if input == 0
      unjoin_all
    else
      host = hosts[input - 1]
      host_mac = host.status(String, :mac_address)

      unjoin_all_devices
      unjoin_all_hosts
      devices.each { |device| perform_join(host, device) }
    end
  end

  def switch(map : Hash(Input, Array(Output)), layer : SwitchLayer? = nil)
    layer ||= SwitchLayer::All
    return unless layer.all? || layer.data? || layer.data2?

    # input hosts => output devices
    map.each do |host_idx, device_idxs|
      # unjoin the devices
      if host_idx == 0
        device_idxs.each do |device_idx|
          device = devices[device_idx - 1]?
          unless device
            logger.warn { "device USB_Device_#{device_idx} not found switching to 0" }
            next
          end
          perform_unjoin(device)
        end
        next
      end

      # join the devices to the following host
      host = hosts[host_idx - 1]?
      unless host
        logger.warn { "host not found in switch USB_Host_#{host_idx} => #{device_idxs}" }
        next
      end

      device_idxs.each do |device_idx|
        device = devices[device_idx - 1]?
        unless device
          logger.warn { "device USB_Device_#{device_idx} not found switching to USB_Host_#{host_idx}" }
          next
        end
        perform_join(host, device)
      end
    end
  end

  protected def unjoin_all_devices
    devices.map(&.unjoin_all).each_with_index do |request, index|
      begin
        request.get
      rescue error
        logger.warn { "failed to unjoin USB_Device_#{index + 1}" }
      end
    end
  end

  protected def unjoin_all_hosts
    hosts.map(&.unjoin_all).each_with_index do |request, index|
      begin
        request.get
      rescue error
        logger.warn { "failed to unjoin USB_Host_#{index + 1}" }
      end
    end
  end

  protected def unjoin_all
    unjoin_all_devices
    unjoin_all_hosts
  end

  protected def perform_join(host, device)
    device_mac = device.status(String, :mac_address)
    host_mac = host.status(String, :mac_address)

    host_joined_to = host.status(Array(String), :joined_to)
    device_joined_to = device.status(Array(String), :joined_to)

    host_joined = host_joined_to.includes?(device_mac)
    device_joined = device_joined_to.includes?(host_mac)

    return if host_joined && device_joined

    if !device_joined
      # unjoin the device from the previous host
      if unjoin_host_mac = device_joined_to.first?
        device.unjoin_all.get
        hosts[host_macs[unjoin_host_mac]].unjoin(device_mac)
      end

      # join the device to the new host
      device.join(host_mac).get
    end

    host.join(device_mac) unless host_joined
  rescue error
    logger.warn(exception: error) { "error joining #{host.module_name}_#{host.index} => #{device.module_name}_#{device.index}" }
  end

  protected def perform_unjoin(device)
    device_mac = device.status(String, :mac_address)
    device_joined_to = device.status(Array(String), :joined_to)
    if unjoin_host_mac = device_joined_to.first?
      device.unjoin_all.get
      hosts[host_macs[unjoin_host_mac]].unjoin(device_mac)
    end
  end
end
