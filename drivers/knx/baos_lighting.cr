require "placeos-driver"
require "placeos-driver/interface/lighting"
require "knx/object_server"

class KNX::BaosLighting < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  # Discovery Information
  descriptive_name "KNX BAOS Lighting"
  generic_name :Lighting
  tcp_port 12004

  default_settings({
    triggers: {
      1 => [
        [161, true, "0: all on"],
        [161, false, "1: all off"],
      ],
    },
  })

  INDICATOR = 0x06_u8

  def on_load
    queue.wait = false
    queue.delay = 40.milliseconds
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek
      logger.debug { "Received: 0x#{bytes.hexstring}" }

      # Ensure message indicator is well-formed
      if bytes.first != INDICATOR
        disconnect
        next 0
      end

      # make sure we can parse the header
      next 0 unless bytes.size > 5

      # extract the request length
      io = IO::Memory.new(bytes)
      header = io.read_bytes(KNX::Header)
      header.request_length.to_i
    end

    on_update
  end

  alias AreaDetails = Hash(Int32, Array(Tuple(Int32, Bool | UInt8, String?)))
  alias AreaLookup = Hash(Int32, Int32)

  @triggers : AreaDetails = AreaDetails.new
  @os : KNX::ObjectServer = KNX::ObjectServer.new
  @area_lookup : AreaLookup = AreaLookup.new

  def on_update
    @triggers = setting?(AreaDetails, :triggers) || AreaDetails.new

    # map the triggers to the area id
    area_lookup = AreaLookup.new
    @triggers.each do |area, triggers|
      triggers.each do |trigger|
        area_lookup[trigger[0]] = area
      end
    end
    @area_lookup = area_lookup
  end

  def disconnected
    schedule.clear
  end

  def connected
    req = @os.status(1).to_slice
    send req, priority: 0

    schedule.every(1.minute) do
      logger.debug { "Maintaining connection" }
      send req, priority: 0
    end
  end

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area_id = area.try &.id
    raise "no area id provided, area: #{area.inspect}" unless area_id

    if trigger_group = @triggers[area_id]?
      details = trigger_group[scene]? # 0, 1, 2 (array index)
    end

    if details
      index, value, _desc = details
      send_request index, value
    else
      send_request area_id, scene
    end
  end

  def lighting_scene?(area : Area? = nil)
    area_id = area.try &.id
    raise "no area id provided, area: #{area.inspect}" unless area_id

    if trigger_group = @triggers[area_id]?
      details = trigger_group[0]?
    end

    if details
      index, value, _desc = details
      send_query index
    else
      send_query area_id
    end
  end

  LEVEL_PERCENTAGE = 0xFF / 100

  # level between 0.0 and 100.0, fade in milliseconds
  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    area_id = area.try &.id
    raise "no area id provided, area: #{area.inspect}" unless area_id

    level = level.clamp(0.0, 100.0)
    level_byte = (level * LEVEL_PERCENTAGE).to_u8

    send_request area_id, level_byte
  end

  # return the current level
  def lighting_level?(area : Area? = nil)
    area_id = area.try &.id
    raise "no area id provided, area: #{area.inspect}" unless area_id

    send_query area_id
  end

  protected def send_request(index, value)
    logger.debug { "Requesting #{index} = #{value}" }
    req = @os.action(index, value).to_slice
    send req, name: "index#{index}_level"
  end

  protected def send_query(num)
    logger.debug { "Requesting value of #{num}" }
    req = @os.status(num).to_slice
    send req, wait: true
  end

  def received(data, task)
    result = @os.read(data)

    # report any errors
    if !result.error.no_error?
      logger.warn { "Error response: #{result.error} (#{result.error_code})" }
      return task.try &.abort
    end

    items = result.data
    logger.debug do
      if items && items.size > 0
        "Index: #{result.header.start_item}, Item Count: #{result.header.item_count}, Start value: 0x#{result.data[0].value.hexstring}"
      else
        "Received #{result.inspect}"
      end
    end

    items.each do |item|
      value_id = item.id
      if area = @area_lookup[value_id]?
        @triggers[area].each_with_index do |trigger, index|
          if value_id == trigger[0]
            # We need to coerce the value
            check = trigger[1]
            case check
            in Bool
              if check == (item.value[0] == 1)
                updated = true
                self["trigger_group_#{area}"] = index
                break
              end
            in UInt8
              if check == item.value[0]
                updated = true
                self["trigger_group_#{area}"] = index
                break
              end
            end
          end
        end
      else
        self["area#{value_id}_level"] = item.value[0]
      end
    end

    task.try &.success
  end
end
