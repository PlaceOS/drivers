require "placeos-driver"
require "http/client"
require "digest"
require "openssl"
require "random/secure"

class Ict::Wx < PlaceOS::Driver
  descriptive_name "ICT Protege WX"
  generic_name :Access
  description %(device driver to control the ICT Protege WX security system)

  # The PlaceOS API
  uri_base "http://159.196.131.157:88/"

  default_settings({
    # PlaceOS API creds, so we can query the zone metadata
    username:     "place",
    password:     "QeS4dijJE9NRJ9"
  })

  @domain : String = "159.196.131.157"
  @port : String = "88"
  @session_id : String = ""
  @username : String = ""
  @password : String = ""
  @password_hash : String = ""
  @session_key : Int64 = 0
  @api_key : String = ""
  @last_event : NamedTuple(time: Int64, user: String, door: String) = { time: Time.utc.to_unix, user: "", door: "" }
  @client : HTTP::Client = HTTP::Client.new(host:  "159.196.131.157", port: "88")

  def on_load
    on_update
  end

  def on_update
    @client = HTTP::Client.new(host: @domain, port: @port)
    @username = setting(String, :username)
    @password = setting(String, :password)
    @session_key = get_session_key
    @api_key = get_api_key
  end

  def connected
    schedule.every(1.second, true) do
      check_events
    end
  end

  def get_session_key
    @session_id = ""
    32.times{ |b| @session_id += (16  * rand).to_i.to_s(16).upcase }
    @password_hash = Digest::SHA1.hexdigest(@password)
    init_session_url = "/PRT_CTRL_DIN_ISAPI.dll?Command&Type=Session&SubType=InitSession&SessionID=#{@session_id}"
    response = @client.get(init_session_url)
    response.body.to_i64
  end

  def get_api_key
    b = xor(@username, @session_key + 1)
    b = Digest::SHA1.hexdigest(b).upcase
    a = xor(@password_hash, @session_key)
    g = Digest::SHA1.hexdigest(a).upcase
    logger.debug{"URL IS:"}
    logger.debug{"#{@domain}:88/PRT_CTRL_DIN_ISAPI.dll?Command&Type=Session&SubType=CheckPassword&Name=#{b}&Password=#{g}&SessionID=#{@session_id}"}
    password_response = @client.get("/PRT_CTRL_DIN_ISAPI.dll?Command&Type=Session&SubType=CheckPassword&Name=#{b}&Password=#{g}&SessionID=#{@session_id}").body
    password_response = password_response.to_i64
    Digest::SHA1.hexdigest(xor(@password_hash, password_response)).upcase[0..15]
  end

  def xor(a : String, c : Int32 | Int64)
    # Pad out the second string
	  binary_string = c.to_s.to_i64(10).to_s(2).rjust(32,'0')
    b = binary_string.size
    d : String = ""
    a.chars.each do |l|
        f = l.ord
        b = 0 == b ? binary_string.size - 8 : b - 8
        g = binary_string[b..b+7].to_i(2).to_s(10)
        f = (f.to_i ^ g.to_i).to_s(16)
        1 == f.size && (f = "0" + f)
        d += f
      end
    d.upcase
  end

  def decrypt_aes(cipherhex : String, api_key : (String | Nil) = nil)
    api_key ||= @api_key
    iv = String.new(cipherhex.hexbytes[0..15])
    ciphertext = String.new(cipherhex.hexbytes[16..-1])
    cipher = OpenSSL::Cipher.new("aes-128-cbc")
    cipher.decrypt
    cipher.key = api_key
    cipher.iv = iv
    io = IO::Memory.new
    io.write(cipher.update(ciphertext))
    io.write(cipher.final)
    io.rewind
    io.gets_to_end
  end

  def encrypt_aes(plaintext : String, api_key : (String | Nil) = nil, session_id : (String | Nil) = nil)
    api_key ||= @api_key
    session_id ||= @session_id
    iv = Random::Secure.random_bytes(8).hexstring.upcase
    cipher = OpenSSL::Cipher.new("aes-128-cbc")
    cipher.encrypt
    cipher.key = api_key
    cipher.iv = iv
    io = IO::Memory.new
    io.write(cipher.update(plaintext))
    io.write(cipher.final)
    io.rewind
    cipher_final = io.to_slice
    session_id + (iv.to_slice.hexstring + cipher_final.hexstring).upcase
  end


  def encrypted_request(path : String, api_key : (String | Nil) = nil, session_id : (String | Nil) = nil)
    begin
      api_key ||= @api_key
      session_id ||= @session_id
      enc_path =  encrypt_aes(path, @api_key, session_id)
      url : String = "/PRT_CTRL_DIN_ISAPI.dll?#{enc_path}"
      res = @client.get(url)
      decrypt_aes(res.body, @api_key)
    rescue 
      @session_key = get_session_key
      @api_key = get_api_key
      puts "RETYING!"
      api_key ||= @api_key
      session_id ||= @session_id
      enc_path =  encrypt_aes(path, @api_key, session_id)
      url = "/PRT_CTRL_DIN_ISAPI.dll?#{enc_path}"
      res = @client.get(url)
      decrypt_aes(res.body, @api_key)
    end
  end

  def check_events
    events = get_events("Update").split("&")
    events.reject! {|e| e[0..9] == "EventCodes"}
    events.each do |event|
      if event =~ /User (.*) Entry Granted (.*) Using/
        puts "#{$1} has accessed #{$2}"
        @last_event = {
          time: Time.utc.to_unix,
          user: $1,
          door: $2
        }
      end
    end if events
  end

  def get_events(type : String = "Latest")
    encrypted_request("Request&Type=Events&SubType=#{type}&Sequence=")
  end

  def get_doors
    encrypted_request("Request&Type=List&SubType=GXT_DOORS_TBL&Sequence=").split("&").map{ |r| r.split("=")[1] }
  end

  def open_door(door_id : String)
    encrypted_request("Command&Type=Control&SubType=GXT_DOORS_TBL&RecId=#{door_id}&Command=1&Sequence=")
  end
end