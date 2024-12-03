require "placeos-driver"
require "./nvx_models"

class Crestron::NvxAddressManager < PlaceOS::Driver
  descriptive_name "Crestron NVX Address Manager"
  generic_name :NvxAddressManager

  description <<-DESC
    Simplified management of NVX encoder multicast addressing.

    Allows a subnet to be assigned with sequential, blocked address
    allocation to all NVX encoders appearing alongside instances of this
    module.

    This is intended to be instantiated in systems containing all NVX
    encoders that share a multicast subnet.
  DESC

  default_settings({
    base_address: "239.8.0.2",
    block_size:   8,
  })

  # https://github.com/Sija/ipaddress.cr
  MULTICAST_ADDRESSES = ::IPAddress::IPv4.new("224.0.0.0/4")

  @base_address : UInt32 = 0_u32
  @block_size : Int32 = 8

  def on_update
    addr = setting(String, :base_address)
    base_addr = ::IPAddress::IPv4.new addr
    @base_address = base_addr.to_u32
    logger.warn { "#{addr} is not a valid multicast address" } unless MULTICAST_ADDRESSES.includes? base_addr
    @block_size = setting(Int32, :block_size)
  end

  def readdress_streams
    logger.debug { "readdressing devices" }

    address_pairs = encoders.zip(addresses)

    interactions = address_pairs.map_with_index(1) do |(mod, ip_u32), idx|
      ip = ::IPAddress::IPv4.parse_u32(ip_u32)
      logger.debug { "setting encoder #{idx} to #{ip}" }
      mod.multicast_address ip.to_s
    end

    failed = 0
    interactions.each do |request|
      begin
        request.get
      rescue error
        failed += 1
        logger.warn(exception: error) { "addressing NVX devices" }
      end
    end

    raise "#{failed} failed to set stream address" unless failed == 0
    interactions.size
  end

  protected def encoders
    system.implementing(Crestron::Transmitter)
  end

  # returns an iterator of IPv4 addresses represented as 32bit numbers
  protected def addresses
    address_range = (@base_address..MULTICAST_ADDRESSES.last.to_u32)
    address_range.step by: @block_size
  end
end
