require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"
require "mutex"

class Sony::Displays::BraviaRest < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable
  include Interface::Switchable(Input)

  descriptive_name "Sony Bravia REST API"
  generic_name :Display
  description "Driver for Sony Bravia displays via REST API. Requires Pre-Shared Key authentication to be configured on the device."

  default_settings({
    psk: "",  # PSK is required - must be configured on device
  })

  enum Input
    Hdmi1
    Hdmi2
    Hdmi3
    Hdmi4
    Component1
    Component2
    Composite1
    Composite2
    Scart1
    Scart2
    PC
    Cable
    Satellite
    Antenna
    Application
  end

  enum PowerStatus
    Active
    Standby
    Off
  end

  @psk : String = ""
  @power_status : PowerStatus = PowerStatus::Off
  @mute : Bool = false
  @volume : Int32 = 0
  @current_input : Input = Input::Hdmi1
  @request_id : Int32 = 1
  @api_mutex = Mutex.new

  def on_load
    on_update
  end

  def on_update
    psk = setting(String, :psk)
    if psk.nil? || psk.empty?
      logger.warn { "PSK is not configured. Please set the PSK in driver settings." }
      @psk = ""
    else
      @psk = psk
    end
  end

  def connected
    schedule.every(30.seconds) { query_power_status }
    schedule.every(45.seconds) { query_volume_info }
    schedule.every(60.seconds) { query_current_input }
    
    query_power_status
    query_volume_info
    query_current_input
  end

  def disconnected
    schedule.clear
  end

  # Power Control
  def power(state : Bool)
    if state
      power_on
    else
      power_off
    end
  end

  def power? : Bool
    @power_status.active?
  end

  def power_on
    response = send_command("system", "setPowerStatus", [{"status" => true}])
    if response[:success?]
      @power_status = PowerStatus::Active
      self[:power] = true
      self[:power_status] = "on"
    end
    response
  end

  def power_off
    response = send_command("system", "setPowerStatus", [{"status" => false}])
    if response[:success?]
      @power_status = PowerStatus::Standby
      self[:power] = false
      self[:power_status] = "standby"
    end
    response
  end

  def query_power_status
    response = send_command("system", "getPowerStatus", [] of String)
    if response[:success?]
      begin
        result = response[:get].as_a
        if result.size > 0
          status_obj = result[0].as_h
          status = status_obj["status"]?.try(&.as_s)
          if status
            case status.downcase
            when "active"
              @power_status = PowerStatus::Active
              self[:power] = true
              self[:power_status] = "on"
            when "standby"
              @power_status = PowerStatus::Standby
              self[:power] = false
              self[:power_status] = "standby"
            else
              @power_status = PowerStatus::Off
              self[:power] = false
              self[:power_status] = "off"
            end
          end
        end
      rescue ex
        logger.warn(exception: ex) { "Failed to parse power status response" }
      end
    end
    response
  end

  # Volume Control
  def mute(state : Bool = true)
    if state
      mute_on
    else
      mute_off
    end
  end

  def mute_on
    response = send_command("audio", "setAudioMute", [{"status" => true}])
    if response[:success?]
      @mute = true
      self[:audio_mute] = true
    end
    response
  end

  def mute_off
    response = send_command("audio", "setAudioMute", [{"status" => false}])
    if response[:success?]
      @mute = false
      self[:audio_mute] = false
    end
    response
  end

  def muted? : Bool
    @mute
  end

  def volume(level : Int32)
    level = level.clamp(0, 100)
    response = send_command("audio", "setAudioVolume", [{"target" => "speaker", "volume" => level.to_s}])
    if response[:success?]
      @volume = level
      self[:volume] = level
    end
    response
  end

  def volume_up
    volume(@volume + 1)
  end

  def volume_down
    volume(@volume - 1)
  end

  def query_volume_info
    response = send_command("audio", "getVolumeInformation", [] of String)
    if response[:success?]
      begin
        result = response[:get].as_a
        result.each do |item|
          item_hash = item.as_h
          if item_hash["target"]? == "speaker"
            volume_str = item_hash["volume"]?.try(&.as_s)
            mute_val = item_hash["mute"]?.try(&.as_bool)
            
            if volume_str && mute_val.is_a?(Bool)
              @volume = volume_str.to_i
              @mute = mute_val
              self[:volume] = @volume
              self[:audio_mute] = @mute
              break
            end
          end
        end
      rescue ex
        logger.warn(exception: ex) { "Failed to parse volume information response" }
      end
    end
    response
  end

  # Input Control
  def switch_to(input : Input)
    uri = input_to_uri(input)
    response = send_command("avContent", "setPlayContent", [{"uri" => uri}])
    if response[:success?]
      @current_input = input
      self[:input] = input.to_s.downcase
    end
    response
  end

  def switch_to(input : String)
    input_enum = parse_input_string(input)
    return false unless input_enum
    result = switch_to(input_enum)
    result[:success?]
  end

  def input : Input
    @current_input
  end

  def query_current_input
    response = send_command("avContent", "getPlayingContentInfo", [] of String)
    if response[:success?]
      begin
        result = response[:get].as_a
        if result.size > 0
          result_obj = result[0].as_h
          uri = result_obj["uri"]?.try(&.as_s)
          if uri
            input = uri_to_input(uri)
            if input
              @current_input = input
              self[:input] = input.to_s.downcase
            end
          end
        end
      rescue ex
        logger.warn(exception: ex) { "Failed to parse current input response" }
      end
    end
    response
  end

  # Input shortcuts
  def hdmi1; switch_to(Input::Hdmi1); end
  def hdmi2; switch_to(Input::Hdmi2); end
  def hdmi3; switch_to(Input::Hdmi3); end
  def hdmi4; switch_to(Input::Hdmi4); end

  # Additional functionality
  def get_system_information
    send_command("system", "getSystemInformation", [] of String)
  end

  def get_interface_information
    send_command("system", "getInterfaceInformation", [] of String)
  end

  def get_remote_controller_info
    send_command("system", "getRemoteControllerInfo", [] of String)
  end

  def send_ir_code(code : String)
    send_command("system", "actIRCC", [{"ircc" => code}])
  end

  def get_content_list(source : String = "tv")
    send_command("avContent", "getContentList", [{"source" => source}])
  end

  def get_scheme_list
    send_command("avContent", "getSchemeList", [] of String)
  end

  def get_source_list
    send_command("avContent", "getSourceList", [{"scheme" => "tv"}])
  end

  def get_current_time
    send_command("system", "getCurrentTime", [] of String)
  end

  def set_language(language : String)
    send_command("system", "setLanguage", [{"language" => language}])
  end

  def get_text_form(enc_type : String = "")
    params = enc_type.empty? ? [] of String : [{"encType" => enc_type}]
    send_command("appControl", "getTextForm", params)
  end

  def set_text_form(text : String)
    send_command("appControl", "setTextForm", [{"text" => text}])
  end

  def get_application_list
    send_command("appControl", "getApplicationList", [] of String)
  end

  def set_active_app(uri : String)
    send_command("appControl", "setActiveApp", [{"uri" => uri}])
  end

  def terminate_apps
    send_command("appControl", "terminateApps", [] of String)
  end

  def get_application_status_list
    send_command("appControl", "getApplicationStatusList", [] of String)
  end

  def get_web_app_status
    send_command("appControl", "getWebAppStatus", [] of String)
  end

  # Picture settings
  def get_scene_select
    send_command("videoScreen", "getSceneSelect", [] of String)
  end

  def set_scene_select(scene : String)
    send_command("videoScreen", "setSceneSelect", [{"scene" => scene}])
  end

  def get_banner_mode
    send_command("videoScreen", "getBannerMode", [] of String)
  end

  def set_banner_mode(mode : String)
    send_command("videoScreen", "setBannerMode", [{"mode" => mode}])
  end

  def get_pip_sub_screen_position
    send_command("videoScreen", "getPipSubScreenPosition", [] of String)
  end

  def set_pip_sub_screen_position(position : String)
    send_command("videoScreen", "setPipSubScreenPosition", [{"position" => position}])
  end

  # Private helper methods
  private def send_command(service : String, method : String, params) : NamedTuple(success?: Bool, get: JSON::Any)
    # Check if PSK is configured
    if @psk.empty?
      logger.error { "PSK not configured - cannot send command #{method} to #{service}" }
      return {success?: false, get: JSON.parse("{}")}
    end

    @api_mutex.synchronize do
      request_body = {
        "method"  => method,
        "params"  => params,
        "id"      => next_request_id,
        "version" => "1.0",
      }

      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        "X-Auth-PSK"   => @psk,
      }

      begin
        response = post("/sony/#{service}", 
          body: request_body.to_json,
          headers: headers
        )

        case response.status_code
        when 200
          body = response.body
          if body.empty?
            logger.warn { "Empty response body for #{method}" }
            return {success?: false, get: JSON.parse("{}")}
          end
          
          begin
            json_response = JSON.parse(body)
            
            if json_response.as_h.has_key?("error")
              error = json_response["error"].as_a
              logger.warn { "Sony Bravia API error: #{error[1]} (#{error[0]})" }
              {success?: false, get: json_response}
            else
              {success?: true, get: json_response["result"]}
            end
          rescue ex
            logger.error(exception: ex) { "Failed to parse JSON response for #{method}" }
            {success?: false, get: JSON.parse("{}")}
          end
        else
          logger.warn { "Sony Bravia HTTP error: #{response.status_code} - #{response.body}" }
          {success?: false, get: JSON.parse("{}")}
        end
      rescue ex
        logger.error(exception: ex) { "Failed to send command #{method} to #{service}" }
        {success?: false, get: JSON.parse("{}")}
      end
    end
  end

  private def next_request_id : Int32
    @request_id += 1
  end

  private def parse_input_string(input : String) : Input?
    case input.downcase
    when "hdmi1", "hdmi_1", "hdmi 1"
      Input::Hdmi1
    when "hdmi2", "hdmi_2", "hdmi 2"
      Input::Hdmi2
    when "hdmi3", "hdmi_3", "hdmi 3"
      Input::Hdmi3
    when "hdmi4", "hdmi_4", "hdmi 4"
      Input::Hdmi4
    when "component1", "component_1", "component 1"
      Input::Component1
    when "component2", "component_2", "component 2"
      Input::Component2
    when "composite1", "composite_1", "composite 1"
      Input::Composite1
    when "composite2", "composite_2", "composite 2"
      Input::Composite2
    when "scart1", "scart_1", "scart 1"
      Input::Scart1
    when "scart2", "scart_2", "scart 2"
      Input::Scart2
    when "pc"
      Input::PC
    when "cable"
      Input::Cable
    when "satellite"
      Input::Satellite
    when "antenna"
      Input::Antenna
    when "application", "app"
      Input::Application
    else
      nil
    end
  end

  private def input_to_uri(input : Input) : String
    case input
    when .hdmi1?
      "extInput:hdmi?port=1"
    when .hdmi2?
      "extInput:hdmi?port=2"
    when .hdmi3?
      "extInput:hdmi?port=3"
    when .hdmi4?
      "extInput:hdmi?port=4"
    when .component1?
      "extInput:component?port=1"
    when .component2?
      "extInput:component?port=2"
    when .composite1?
      "extInput:composite?port=1"
    when .composite2?
      "extInput:composite?port=2"
    when .scart1?
      "extInput:scart?port=1"
    when .scart2?
      "extInput:scart?port=2"
    when .pc?
      "extInput:pc?port=1"
    when .cable?
      "extInput:cec?type=tuner&port=1"
    when .satellite?
      "extInput:cec?type=tuner&port=2"
    when .antenna?
      "tv:dvbt"
    when .application?
      "app:"
    else
      "extInput:hdmi?port=1"
    end
  end

  private def uri_to_input(uri : String) : Input?
    case uri
    when /extInput:hdmi\?port=1/
      Input::Hdmi1
    when /extInput:hdmi\?port=2/
      Input::Hdmi2
    when /extInput:hdmi\?port=3/
      Input::Hdmi3
    when /extInput:hdmi\?port=4/
      Input::Hdmi4
    when /extInput:component\?port=1/
      Input::Component1
    when /extInput:component\?port=2/
      Input::Component2
    when /extInput:composite\?port=1/
      Input::Composite1
    when /extInput:composite\?port=2/
      Input::Composite2
    when /extInput:scart\?port=1/
      Input::Scart1
    when /extInput:scart\?port=2/
      Input::Scart2
    when /extInput:pc/
      Input::PC
    when /extInput:cec\?type=tuner&port=1/
      Input::Cable
    when /extInput:cec\?type=tuner&port=2/
      Input::Satellite
    when /tv:dvbt/
      Input::Antenna
    when /app:/
      Input::Application
    else
      nil
    end
  end
end