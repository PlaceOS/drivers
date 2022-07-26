require "placeos-driver"
require "digest"

class Ict::Wx < PlaceOS::Driver
  descriptive_name "ICT Protege WX"
  generic_name :Access
  description %(device driver to control the ICT Protege WX security system)

  # The PlaceOS API
  uri_base "http://159.196.131.157:88/"

  default_settings({
    # PlaceOS API creds, so we can query the zone metadata
    username:     "place"
  })

  @domain : String = "http://159.196.131.157:88/"
  @session_id : String = ""
  @username : String = ""
  @password : String = ""
  @session_key : String = ""
  @api_key : String = ""

  def on_load
    on_update
  end

  def on_update
    @username = setting(String, :username)
    @password = setting(String, :password)
    @session_key = get_session_key
    @api_key = get_api_key
  end

  def get_session_key
    # Generate a session ID
    32.times{ |b| @session_id ||= ""; @session_id += (16  * rand).to_i.to_s(16).upcase }
    @password_hash = Digest::SHA1.hexdigest(@password)
    init_session_url = "#{@domain}/PRT_CTRL_DIN_ISAPI.dll?Command&Type=Session&SubType=InitSession&SessionID=#{@session_id}"
    get(init_session_url).body
  end

  def get_api_key
    b = xor(@username, @session_key.to_i(10) + 1)
    b = Digest::SHA1.hexdigest(b).upcase
    logger.error { "GOT HERE" }
    if !@password_hash.nil?
        a = xor(@password_hash, @session_key)
        g = Digest::SHA1.hexdigest(a).upcase
        password_response = get("#{@domain}/PRT_CTRL_DIN_ISAPI.dll?Command&Type=Session&SubType=CheckPassword&Name=#{b}&Password=#{g}&SessionID=#{@session_id}", 
        params: {
            "Command"   => "",
            "Type"      => "Session",
            "SubType"   => "CheckPassword",
            "Name"      => b,
            "Password"  => g,
            "SessionID" => @session_id,
        }).body
        password_response = Digest::SHA1.hexdigest(xor(@password_hash, password_response)).upcase[0..15]
    end
    (password_response || "")
  end

  protected def xor(a,c)
    # Pad out the second string
    c = "%032d" % c.to_s.to_i(10).to_s(2)
    b = c.size
    d = ""
    (a || "").chars.each do |l|
      f = l.ord
      b = 0 == b ? c.size - 8 : b - 8
      g = c[b..b+7].to_i(2).to_s(10)
      f = (f.to_i ^ g.to_i).to_s(16)
      1 == f.size && (f = "0" + f)
      d += f
    end
    d.upcase
  end
end