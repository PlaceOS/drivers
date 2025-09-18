require "uri"

module Crestron::CresNextAuth
  protected getter xsrf_token : String = ""

  getter authenticated : Bool = false

  def authenticate : Nil
    logger.debug { "Authenticating" }
    was_authenticated = @authenticated
    @authenticated = false

    # some devices require referer and origin to accept the login
    uri = URI.parse config.uri.not_nil!
    host = uri.host

    response = post("/userlogin.html", headers: {
      "Content-Type" => "application/x-www-form-urlencoded",
      "Referer"      => "https://#{host}/userlogin.html",
      "Origin"       => "https://#{host}",
    }, body: URI::Params.build { |form|
      form.add("login", setting(String, :username))
      form.add("passwd", setting(String, :password))
    })

    case response.status_code
    when 200, 302
      auth_cookies = %w(AuthByPasswd iv tag userid userstr)
      if (auth_cookies - response.cookies.to_h.keys).empty?
        @xsrf_token = response.headers["CREST-XSRF-TOKEN"]? || ""
        @authenticated = true
        begin
          queue.set_connected(true) unless was_authenticated
        rescue
        end
        logger.debug { "Authenticated" }
      else
        error = "Device did not return all auth information"
      end
    when 403
      error = "Invalid credentials"
    else
      error = "Unexpected response (HTTP #{response.status})"
    end

    self[:authenticated] = @authenticated
    self[:auth_error] = error

    if error
      logger.error { error }
      queue.set_connected(false)
      raise error
    end
  end

  def logout
    response = post "/logout"

    case response.status
    when 302
      logger.debug { "Logout successful" }
      @authenticated = false
      true
    else
      logger.warn { "Unexpected response (HTTP #{response.status})" }
      false
    end
  ensure
    @xsrf_token = ""
    transport.cookies.clear
    schedule.clear
    disconnect
  end
end
