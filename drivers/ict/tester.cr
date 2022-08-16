require "placeos-driver"

class Ict::Tester < PlaceOS::Driver
  descriptive_name "Test Driver"
  generic_name :Tester
  description %(device driver to test the ICT Protege WX security system)


  default_settings({
    # PlaceOS API creds, so we can query the zone metadata
    username:     "place",
    password:     "12345678"
  })

  @domain : String = "http://159.196.131.157:88/"
  @session_id : String = ""
  @username : String = ""
  @password : String = ""
  @password_hash : String = ""
  @session_key : Int64 = 0
  @api_key : String = ""

  def on_load
    on_update
  end

  def on_update
    logger.debug { "GOT TO ON UPDATE" }
    @session_key = get_session_key
    @api_key = get_api_key
  end

  def get_session_key
    logger.debug { "GOT TO SESSION KEY METHOD "}
    HTTP::Client.get("https://google.com")
    1478231749124
  end

  def get_api_key
    
    logger.debug { "GOT TO API KEY METHOD "}
    "BLAH"
  end

end