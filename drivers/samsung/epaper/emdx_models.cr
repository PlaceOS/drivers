require "json"

# Samsung Multiple Display Control (MDC) framing and the content manifest used by
# Samsung Color E-Paper (EMDX) displays.
#
# MDC framing: https://github.com/vgavro/samsung-mdc
# Content download command and manifest: https://github.com/WeeJeWel/node-samsung-emdx
# EM32DX command inventory: https://github.com/taylorRichie/node-samsung-emdx/blob/main/docs/MDC-COMMANDS.md
module Samsung::Epaper
  HEADER   = 0xAA_u8
  RESPONSE = 0xFF_u8
  ACK      = 0x41_u8

  # sub-command of `Command::Status` that reports the battery
  STATUS_BATTERY = 0x73_u8

  # sub-command and data type that precede the URL in `Command::ContentDownload`
  CONTENT_URL = Bytes[0x53, 0x80]

  # the URL length is sent as a single byte
  MAX_URL_BYTES = 255

  enum Command : UInt8
    SerialNumber    = 0x0B
    SoftwareVersion = 0x0E
    Status          = 0x1B
    DeviceName      = 0x67
    ContentDownload = 0xC7
  end

  class MDCError < Exception
    enum Code
      Unreachable
      IncorrectPin
      Blocked
      Rejected
      Protocol
    end

    getter code : Code

    def initialize(@code : Code, message : String)
      super(message)
    end
  end

  # Sum of the bytes modulo 256
  def self.checksum(bytes : Bytes) : UInt8
    bytes.reduce(0_u8) { |sum, byte| sum &+ byte }
  end

  # Request frame: header, command, display id, data length, data, checksum.
  # The checksum covers every byte after the header.
  def self.request(command : Command, data : Bytes = Bytes.empty, display_id : UInt8 = 0_u8) : Bytes
    raise ArgumentError.new("MDC data is limited to 255 bytes") if data.size > 255

    frame = Bytes.new(data.size + 5)
    frame[0] = HEADER
    frame[1] = command.value
    frame[2] = display_id
    frame[3] = data.size.to_u8
    data.copy_to(frame + 4)
    frame[-1] = checksum(frame[1, frame.size - 2])
    frame
  end

  # Data for `Command::ContentDownload` pointing the display at a manifest
  def self.content_download_data(url : String) : Bytes
    raise ArgumentError.new("content URL is longer than #{MAX_URL_BYTES} bytes: #{url}") if url.bytesize > MAX_URL_BYTES

    io = IO::Memory.new
    io.write CONTENT_URL
    io.write_byte url.bytesize.to_u8
    io.write url.to_slice
    io.to_slice
  end

  # Response frame: header, 0xFF, display id, length, ACK or NAK, command, payload, checksum.
  # The length counts the ACK or NAK byte, the command and the payload.
  struct Response
    getter command : UInt8
    getter? ack : Bool
    getter payload : Bytes

    def initialize(@command, @ack, @payload)
    end

    def self.parse(frame : Bytes) : Response
      valid = frame.size >= 7 && frame[0] == HEADER && frame[1] == RESPONSE && frame[3].to_i + 5 == frame.size
      raise MDCError.new(:protocol, "malformed MDC response: #{frame.hexstring}") unless valid
      unless Samsung::Epaper.checksum(frame[1, frame.size - 2]) == frame[-1]
        raise MDCError.new(:protocol, "MDC response checksum mismatch: #{frame.hexstring}")
      end

      new(frame[5], frame[4] == ACK, frame[6, frame.size - 7])
    end
  end

  struct Battery
    include JSON::Serializable

    getter percent : Int32
    getter? charging : Bool

    def initialize(@percent, @charging)
    end

    # Payload layout: sub-command, charging, present, health, level
    def self.parse(payload : Bytes) : Battery
      unless payload.size >= 5 && payload[0] == STATUS_BATTERY
        raise MDCError.new(:protocol, "unexpected battery status: #{payload.hexstring}")
      end
      new(payload[4].to_i, payload[1] == 1_u8)
    end
  end

  struct DeviceStatus
    include JSON::Serializable

    getter name : String?
    getter serial_number : String?
    getter firmware : String?
    getter battery : Battery?

    def initialize(@name, @serial_number, @firmware, @battery)
    end
  end

  # Picture formats listed in the EMDX user guide
  enum ImageFormat
    JPEG
    PNG
    BMP

    def extension : String
      case self
      in .jpeg? then "jpg"
      in .png?  then "png"
      in .bmp?  then "bmp"
      end
    end

    def mime_type : String
      case self
      in .jpeg? then "image/jpeg"
      in .png?  then "image/png"
      in .bmp?  then "image/bmp"
      end
    end

    def self.detect(bytes : Bytes) : ImageFormat?
      if bytes.size >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        JPEG
      elsif bytes.size >= 8 && bytes[0, 8] == Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        PNG
      elsif bytes.size >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D
        BMP
      end
    end
  end

  # Content manifest, in the shape the Samsung E-Paper app sends in Mobile mode
  struct Manifest
    include JSON::Serializable

    # Directory the display stores mobile content in, as sent by the E-Paper app
    CONTENT_ROOT = "/home/owner/content/Downloads/vxtplayer/epaper/mobile/contents"

    struct Content
      include JSON::Serializable

      getter image_url : String
      getter file_id : String
      getter file_path : String
      getter duration : Int32
      getter file_size : String
      getter file_name : String

      def initialize(@image_url, @file_id, @file_path, @duration, @file_size, @file_name)
      end
    end

    struct Schedule
      include JSON::Serializable

      getter start_date : String
      getter stop_date : String
      getter start_time : String
      getter contents : Array(Content)

      def initialize(@start_date, @stop_date, @start_time, @contents)
      end
    end

    getter schedule : Array(Schedule)
    getter name : String
    getter version : Int32
    getter create_time : String
    getter id : String
    getter program_id : String
    getter content_type : String
    getter deploy_type : String

    def initialize(@schedule, @name, @version, @create_time, @id, @program_id, @content_type, @deploy_type)
    end

    # *id* is an upper case UUID naming the content
    def self.build(id : String, image_url : String, size : Int32, format : ImageFormat, name : String, now : Time = Time.local) : Manifest
      file_name = "#{id}.#{format.extension}"
      content = Content.new(
        image_url: image_url,
        file_id: id,
        file_path: "#{CONTENT_ROOT}/#{id}/#{file_name}",
        duration: 91326,
        file_size: size.to_s,
        file_name: file_name,
      )
      schedule = Schedule.new(
        start_date: "1970-01-01",
        stop_date: "2999-12-31",
        start_time: "00:00:00",
        contents: [content],
      )
      new(
        schedule: [schedule],
        name: name,
        version: 1,
        create_time: now.to_s("%Y-%m-%d %H:%M:%S"),
        id: id,
        program_id: "com.samsung.ios.ePaper",
        content_type: "ImageContent",
        deploy_type: "MOBILE",
      )
    end

    # JSON with escaped forward slashes, as the E-Paper app sends it
    def serialise : String
      to_json.gsub('/', "\\/")
    end
  end

  # Result of sending content to a display
  struct Delivery
    include JSON::Serializable

    getter id : String
    getter format : ImageFormat
    getter bytes : Int32
    getter manifest_url : String
    getter delivered_at : Int64

    def initialize(@id, @format, @bytes, @manifest_url, @delivered_at)
    end
  end
end
