require "placeos-driver/spec"
require "http/client"
require "http/server"
require "openssl_ext"
require "./emdx_models"

# Stand-in for an EMDX display: secured MDC over TLS, then downloads content over HTTP
class FakeEMDX
  getter port : Int32
  getter sessions : Int32 = 0
  getter failed_pins : Int32 = 0
  getter content_urls = [] of String
  getter raw_manifests = [] of String
  getter manifests = [] of Samsung::Epaper::Manifest
  getter images = [] of Bytes
  getter errors = [] of String
  property? download : Bool = true

  def initialize(@pin : String)
    key = OpenSSL::PKey::RSA.new(2048)
    name = OpenSSL::X509::Name.new
    name.add_entry("CN", "fake-emdx")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1_u64
    cert.subject = name
    cert.issuer = name
    cert.public_key = key
    cert.not_before = OpenSSL::ASN1::Time.days_from_now(0)
    cert.not_after = OpenSSL::ASN1::Time.days_from_now(1)
    cert.sign(key, OpenSSL::Digest.new("SHA256"))

    cert_path = File.tempname("fake-emdx", ".crt")
    key_path = File.tempname("fake-emdx", ".key")
    File.write(cert_path, cert.to_pem)
    File.write(key_path, key.to_pem)
    @context = OpenSSL::SSL::Context::Server.new
    @context.certificate_chain = cert_path
    @context.private_key = key_path

    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  # Waits for the display to hold *count* images
  def wait_for_images(count : Int32, timeout = 3.seconds) : Nil
    deadline = Time.monotonic + timeout
    until @images.size >= count || @errors.size > 0 || Time.monotonic > deadline
      sleep 20.milliseconds
    end
  end

  private def accept_loop
    while client = @server.accept?
      spawn { handle(client) }
    end
  end

  private def handle(client : TCPSocket)
    client << "MDCSTART<<TLS>>"
    client.flush
    tls = OpenSSL::SSL::Socket::Server.new(client, @context, sync_close: true)

    buffer = Bytes.new(32)
    pin = String.new(buffer[0, tls.read(buffer)])
    if pin != @pin
      @failed_pins += 1
      tls << "MDCAUTH<<FAIL:0x01>>"
      tls.flush
      return
    end

    @sessions += 1
    tls << "MDCAUTH<<PASS>>"
    tls.flush

    while tls.read_byte == 0xAA
      head = Bytes.new(3)
      tls.read_fully(head)
      data = Bytes.new(head[2].to_i)
      tls.read_fully(data)
      tls.read_byte
      respond(tls, head[0], data)
    end
  rescue IO::Error
  ensure
    tls.try(&.close) rescue nil
    client.close rescue nil
  end

  private def respond(io : IO, command : UInt8, data : Bytes)
    case command
    when 0x0B then reply(io, command, true, "FAKE0000000001".to_slice)
    when 0x0E then reply(io, command, true, "S-FAKE-1000.0".to_slice)
    when 0x67 then reply(io, command, true, "Fake EM13DX".to_slice)
    when 0x1B
      if data[0]? == 0x73
        reply(io, command, true, Bytes[0x73, 0x00, 0x01, 0x01, 64, 0x00, 0x00])
      else
        reply(io, command, false)
      end
    when 0xC7
      if data.size > 3 && data[0] == 0x53 && data[1] == 0x80
        url = String.new(data[3, data[2]])
        @content_urls << url
        reply(io, command, true, Bytes[0x53])
        spawn { fetch(url) } if download?
      else
        reply(io, command, false)
      end
    else
      reply(io, command, false)
    end
  end

  # Response frame: header, 0xFF, display id, length, ACK or NAK, command, payload, checksum
  private def reply(io : IO, command : UInt8, ack : Bool, payload : Bytes = Bytes.empty)
    body = IO::Memory.new
    body.write_byte 0xFF_u8
    body.write_byte 0x00_u8
    body.write_byte (payload.size + 2).to_u8
    body.write_byte(ack ? 0x41_u8 : 0x4E_u8)
    body.write_byte command
    body.write payload
    bytes = body.to_slice

    io.write_byte 0xAA_u8
    io.write bytes
    io.write_byte bytes.reduce(0_u8) { |sum, byte| sum &+ byte }
    io.flush
  end

  private def fetch(url : String)
    raw = HTTP::Client.get(url, &.body_io.gets_to_end)
    @raw_manifests << raw
    manifest = Samsung::Epaper::Manifest.from_json(raw)
    @manifests << manifest

    content = manifest.schedule.first.contents.first
    image = HTTP::Client.get(content.image_url, &.body_io.getb_to_end)
    raise "manifest says #{content.file_size} bytes but got #{image.size}" unless image.size.to_s == content.file_size
    @images << image
  rescue error
    @errors << error.message.to_s
  end
end

DriverSpecs.mock_driver "Samsung::Epaper::EMDX" do
  pin = "246810"
  display = FakeEMDX.new(pin)
  display_settings = {
    pin:              pin,
    mdc_port:         display.port,
    content_port:     0,
    download_timeout: 3,
  }
  settings(display_settings)

  jpeg = Bytes.new(2048) { |index| index < 4 ? Bytes[0xFF, 0xD8, 0xFF, 0xE0][index] : 7_u8 }
  png = Bytes.new(1024) { |index| index < 8 ? Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A][index] : 9_u8 }

  image_server = HTTP::Server.new do |context|
    response = context.response
    case context.request.path
    when "/start"
      response.status = :found
      response.headers["Location"] = "/middle"
    when "/middle"
      response.status = :moved_permanently
      response.headers["Location"] = "files/poster.png"
    when "/files/poster.png"
      response.content_type = "image/png"
      response.write png
    when "/loop"
      response.status = :found
      response.headers["Location"] = "/loop"
    else
      response.status = :not_found
    end
  end
  image_port = image_server.bind_unused_port.port
  spawn { image_server.listen }
  Fiber.yield

  it "should read the display status" do
    status_response = exec(:query_status).get
    device = Samsung::Epaper::DeviceStatus.from_json(status_response.to_json)
    device.name.should eq "Fake EM13DX"
    device.serial_number.should eq "FAKE0000000001"
    device.firmware.should eq "S-FAKE-1000.0"
    device.battery.try(&.percent).should eq 64

    status[:device_name].should eq "Fake EM13DX"
    status[:battery_level].should eq 64
    status[:charging].as_bool.should be_false
  end

  it "should show a base64 picture" do
    result = exec(:show_image_base64, Base64.strict_encode(jpeg)).get
    display.wait_for_images(1)
    display.errors.should be_empty
    display.images.last.should eq jpeg

    delivery = Samsung::Epaper::Delivery.from_json(result.to_json)
    delivery.format.should eq Samsung::Epaper::ImageFormat::JPEG
    delivery.bytes.should eq jpeg.size

    url = display.content_urls.last
    url.should eq delivery.manifest_url
    url.bytesize.should be <= 255
    url.should start_with "http://127.0.0.1:"

    manifest = display.manifests.last
    manifest.deploy_type.should eq "MOBILE"
    manifest.program_id.should eq "com.samsung.ios.ePaper"
    manifest.content_type.should eq "ImageContent"
    content = manifest.schedule.first.contents.first
    content.file_size.should eq jpeg.size.to_s
    content.file_name.should eq "#{delivery.id}.jpg"
    content.file_path.should end_with "/#{delivery.id}/#{delivery.id}.jpg"
    display.raw_manifests.last.should contain "http:\\/\\/127.0.0.1"

    status[:last_delivery]["id"].should eq delivery.id
    status[:content_port].as_i.should be > 0
  end

  it "should accept a data URI" do
    count = display.images.size
    exec(:show_image_base64, "data:image/jpeg;base64,#{Base64.encode(jpeg)}").get
    display.wait_for_images(count + 1)
    display.images.last.should eq jpeg
  end

  it "should follow redirects when showing a picture from a URL" do
    count = display.images.size
    result = exec(:show_image_url, "http://127.0.0.1:#{image_port}/start").get
    display.wait_for_images(count + 1)
    display.errors.should be_empty
    display.images.last.should eq png

    delivery = Samsung::Epaper::Delivery.from_json(result.to_json)
    delivery.format.should eq Samsung::Epaper::ImageFormat::PNG
    display.manifests.last.schedule.first.contents.first.file_name.should end_with ".png"
  end

  it "should show a standby image" do
    count = display.images.size
    exec(:set_background_image, "http://127.0.0.1:#{image_port}/files/poster.png").get
    display.wait_for_images(count + 1)
    display.images.last.should eq png
  end

  it "should give up on a redirect loop" do
    sessions = display.sessions
    expect_raises(Exception, /too many redirects/) do
      exec(:show_image_url, "http://127.0.0.1:#{image_port}/loop").get
    end
    display.sessions.should eq sessions
  end

  it "should refuse unsupported pictures without contacting the display" do
    sessions = display.sessions
    expect_raises(Exception, /unsupported picture format/) do
      exec(:show_image_base64, Base64.strict_encode("GIF89a not supported")).get
    end
    expect_raises(Exception, /not valid base64/) do
      exec(:show_image_base64, "!!!").get
    end
    display.sessions.should eq sessions
  end

  it "should report when the display does not download the content" do
    display.download = false
    expect_raises(Exception, /did not download the manifest/) do
      exec(:show_image_base64, Base64.strict_encode(jpeg)).get
    end
    display.download = true
  end

  it "should stop using a PIN the display rejects" do
    settings(display_settings.merge({pin: "111111"}))
    expect_raises(Exception, /rejected the PIN/) do
      exec(:query_status).get
    end
    display.failed_pins.should eq 1

    expect_raises(Exception, /update the pin setting/) do
      exec(:query_status).get
    end
    display.failed_pins.should eq 1

    settings(display_settings)
    exec(:query_status).get
    status[:serial_number].should eq "FAKE0000000001"
  end

  image_server.close
end
