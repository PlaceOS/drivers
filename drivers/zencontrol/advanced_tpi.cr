require "placeos-driver"
require "placeos-driver/interface/lighting"
require "bindata"

# Documentation: https://aca.im/driver_docs/zencontrol/Advanced_Third_Party_Interface_API_Document.pdf

class Zencontrol::AdvancedTPI < PlaceOS::Driver
  include Interface::Lighting::Scene
  include Interface::Lighting::Level
  alias Area = Interface::Lighting::Area

  generic_name :Lighting
  descriptive_name "Zencontrol Advanced Lighting API"
  description "Uses the advanced zencontrol third party interface UDP or TCP API"

  # NOTE:: Multicast update events are sent on address: 239.255.90.67 port: 6969
  udp_port 5108

  default_settings({
    api_version: 4,
  })

  def on_load
    # size is the 3rd byte
    transport.tokenizer = Tokenizer.new do |io|
      bytes = io.peek
      # Ensure message indicator is well-formed
      logger.debug { "Received: #{bytes.hexstring}" }
      # [type, sequence, length, [data], checksum]
      # return 0 if the message is incomplete
      bytes.size < 3 ? 0 : (bytes[2].to_i + 4)
    end

    on_update
  end

  def on_update
    @version = setting?(UInt8, :api_version) || 4_u8
  end

  @version : UInt8 = 4_u8
  @sequence : UInt8 = 0_u8

  protected def next_sequence_num
    seq = @sequence
    if seq == 255_u8
      @sequence = 0_u8
    else
      @sequence = seq + 1_u8
    end
    seq
  end

  # Using indirect commands
  def trigger(area : UInt32, scene : UInt32)
    area = Area.new(area)
    set_lighting_scene(scene, area)
  end

  # Using direct command
  def light_level(area : UInt32, level : Float64)
    area = Area.new(area)
    set_lighting_level(level, area)
  end

  # ==================
  # Lighting Interface
  # ==================

  def set_lighting_scene(scene : UInt32, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    # Most likely you just want to call a scene on a paricular group by adding 64 to the group number for Address.
    area = area.as(Area)
    area_id = area.id.as(UInt32)
    area_id = area_id.clamp(0, 191) + 64 unless area_id == 0xFF_u32

    # DALI_SCENE
    self[area.to_s] = scene
    basic_request(0xA1_u8, area_id.to_u8, scene)
  end

  def lighting_scene?(area : Area? = nil)
    # DALI_QUERY_LAST_SCENE
    area_id = area.as(Area).id.as(UInt32).clamp(0, 191) + 64
    basic_request(0xAD_u8, area_id.to_u8)
  end

  LEVEL_PERCENTAGE = 0xFF / 100

  def set_lighting_level(level : Float64, area : Area? = nil, fade_time : UInt32 = 1000_u32)
    # Levels can be called on groups by adding 64 to the group number
    area = area.as(Area)
    area_id = area.id.as(UInt32)
    area_id = area_id.clamp(0, 191) + 64 unless area_id == 0xFF_u32

    # Levels are percentage based (on the PlaceOS side)
    level = level.clamp(0.0, 100.0)
    level_actual = (level * LEVEL_PERCENTAGE).round.to_u32

    # DALI_ARC_LEVEL
    basic_request(0xA2_u8, area_id.to_u8, level_actual)
  end

  def lighting_level?(area : Area? = nil)
    # DALI_QUERY_LEVEL
    area_id = area.as(Area).id.as(UInt32).clamp(0, 191) + 64
    basic_request(0xAA_u8, area_id.to_u8)
  end

  # ==================
  # Request Building
  # ==================

  class BasicRequest < BinData
    endian big

    uint8 :version
    uint8 :sequence
    uint8 :command
    uint8 :address
    bit_field do
      bits 24, :data
    end
    uint8 :checksum, value: ->{
      version ^ sequence ^ command ^ address ^ (data >> 16 & 0xFF).to_u8 ^ (data >> 8 & 0xFF).to_u8 ^ (data & 0xFF).to_u8
    }
  end

  class ::PlaceOS::Driver::Task
    property request_payload : Zencontrol::AdvancedTPI::BasicRequest? = nil
  end

  protected def basic_request(command : UInt8, address : UInt8, data : UInt32 = 0_u32, **options)
    # build the message
    request = BasicRequest.new
    request.version = @version
    request.sequence = next_sequence_num
    request.command = command
    request.address = address
    request.data = data

    # send the request
    send(request, **options)
  end

  # ====================
  # RESPONSE PROCESSING
  # ====================

  ERROR_CODES = {
    0x01_u8 => "The checksum check failed",
    0x02_u8 => "A short on the DALI line was detected",
    0x03_u8 => "A receive error occured",
    0x04_u8 => "The command in the request is unrecognised",
    0xB0_u8 => "The command requested relies on a paid feature that hasn't been purchsed",
    0xB1_u8 => "Invalid arguments supplied for the given command in the re quest",
    0xB2_u8 => "The command couldn't be processed",
    0xB3_u8 => "The queue or buffer that's required to process the command in the request
    is full or broken",
    0xB4_u8 => "The command in the request may stream multiple responses back, but this
    feature isn't available for some reason",
    0xB5_u8 => "The DALI related request couldn't be processed due to an error",
    0xB6_u8 => "There are an insufficient number of the required resource remaining service
    the request",
    0xB7_u8 => "An unexpected result occurred",
  }

  enum ResponseType
    Okay     = 0xA0
    Answer   = 0xA1
    NoAnswer = 0xA2
    Error    = 0xA3
  end

  class ResponseFrame < BinData
    endian big

    enum_field UInt8, type : ResponseType = ResponseType::Error
    uint8 :sequence
    uint8 :size
    bytes :bytes, length: ->{ size }
    uint8 :checksum, verify: ->{
      sum = type.to_u8 ^ sequence ^ size
      checksum == bytes.reduce(sum) { |acc, i| i ^ acc }
    }
  end

  def received(data, task)
    logger.debug { "Zencontrol sent: #{data.hexstring}" }

    io = IO::Memory.new(data)
    response = io.read_bytes ResponseFrame

    case response.type
    when .okay?, .no_answer?
      # no processing required
    when .answer?
      if (request = task.try(&.request_payload)) && request.sequence == response.sequence
        case request.command
        when 0xAD_u8 # DALI_QUERY_LAST_SCENE
          area = Area.new((request.address - 64_u8).to_u32)
          self[area.to_s] = response.bytes[0]
        when 0xAA_u8 # DALI_QUERY_LEVEL
          area = Area.new((request.address - 64_u8).to_u32)
          self[area.append("level").to_s] = response.bytes[0]
        else
          logger.debug { "unknown answer for #{request.command.to_s(16)}\n - req: #{request.to_slice.hexstring}\n - resp: #{response.to_slice.hexstring}" }
        end
      end
    when .error?
      error_code = response.bytes[0]
      error_message = ERROR_CODES[error_code]?
      logger.error { "request failed with code #{error_code}, message: #{error_message}" }
      return task.try &.abort(error_message)
    end

    # check if we are expecting a frame
    if request = task.try(&.request_payload)
      if request.sequence == response.sequence
        return task.try &.success
      else # ignore this packet
        return
      end
    end
    task.try &.success
  end
end
