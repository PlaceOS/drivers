module Gantner; end

require "openssl/cipher"
require "./json_models"
require "base64"
require "uuid"
require "set"

# Documentation: https://aca.im/driver_docs/gantner/GAT-Relaxx-JSON-Interface-Description-2.10.pdf
# REST Docs: https://doc.gantner.com/RelaxxDocs/GatRelaxxRestAPI.yaml
#            https://aca.im/driver_docs/gantner/GatRelaxxRestAPI.yaml
# PC Application
# User = Administrator
# PW = Mirone59

class Gantner::Relaxx::ProtocolJSON < PlaceOS::Driver
  # Discovery Information
  tcp_port 8237
  descriptive_name "Gantner GAT Relaxx JSON API"
  generic_name :Lockers

  @authenticated : Bool = false
  @password : String = "GAT"

  # Lists of locker IDs
  @locker_ids : Set(String) = Set(String).new
  @lockers_in_use : Set(String) = Set(String).new

  def on_load
    # 0x02 (Start of frame) and 0x03 (End of frame)
    transport.tokenizer = Tokenizer.new(Bytes[0x03])
    on_update
  end

  def on_update
    @password = setting?(String, :password) || "GAT"
  end

  # Converts the data to bytes and wraps it into a frame
  private def send_frame(data, **options)
    logger.debug { "requesting #{data[:Caption]}, id #{data[:Id]}" }
    send "\x02#{data.to_json}\x03", **options
  end

  private def new_request_id
    UUID.random.to_s.upcase
  end

  def connected
    self["authenticated"] = @authenticated = false
    request_auth_string

    schedule.every(40.seconds) do
      logger.debug { "-- maintaining connection" }
      @authenticated ? keep_alive : request_auth_string
    end
  end

  def disconnected
    schedule.clear
  end

  def keep_alive
    send_frame({
      Caption: "KeepAliveRequest",
      Id:      new_request_id,
    }, priority: 0)
  end

  def request_auth_string
    send_frame({
      Caption: "AuthenticationRequestA",
      Id:      new_request_id,
    }, priority: 9998)
  end

  private def login(authentication_string : String)
    cipher = OpenSSL::Cipher.new("aes-256-cbc")
    cipher.padding = true
    cipher.decrypt

    # LE for little endian and avoids a byte order mark
    password = @password.encode("UTF-16LE")

    key = IO::Memory.new(Bytes.new(32))
    key.write password

    iv = IO::Memory.new(Bytes.new(16))
    iv.write password

    cipher.key = key.to_slice
    cipher.iv = iv.to_slice

    decrypted_data = IO::Memory.new
    content = Base64.decode(authentication_string)
    decrypted_data.write cipher.update(content)
    decrypted_data.write cipher.final
    decrypted_data.rewind

    # Return the decrypted string
    decrypted = String.new(decrypted_data.to_slice, "UTF-16LE")

    send_frame({
      Caption: "AuthenticationRequestB",
      Id:      new_request_id,

      # Locker system expects an integer here
      AuthenticationString: decrypted.to_i,
    }, priority: 9999)
  end

  def open_locker(locker_number : String, locker_group : String? = nil)
    set_open_state(true, locker_number, locker_group)
  end

  def close_locker(locker_number : String, locker_group : String? = nil)
    set_open_state(false, locker_number, locker_group)
  end

  def set_open_state(open : Bool, locker_number : String, locker_group : String? = nil)
    action = open ? "0" : "1"

    # Detect if this is a GUID
    task = if locker_number.includes?("-")
             send_frame({
               Caption:  "ExecuteLockerActionRequest",
               Id:       new_request_id,
               Action:   action,
               LockerId: locker_number,
             })
           else
             request = {
               Caption:      "ExecuteLockerActionRequest",
               Id:           new_request_id,
               Action:       action,
               LockerNumber: locker_number,
             }
             if locker_group
               send_frame(request.merge({LockerGroupId: locker_group}))
             else
               send_frame(request)
             end
           end

    task
  end

  def query_lockers(free_only : Bool = false)
    send_frame({
      Caption:             "GetLockersRequest",
      Id:                  new_request_id,
      FreeLockersOnly:     free_only,
      PersonalLockersOnly: false,
    })
  end

  def received(data, task)
    # Ignore the framing bytes
    data = String.new(data)[1..-2]
    logger.debug { "Gantner Relaxx sent: #{data}" }
    json = JSON.parse(data)

    # Ignore if a notification as we still might be expecting a response
    return parse_notify(json["Caption"].as_s, data) if json["IsNotification"].as_bool

    # Check result of the request
    result = Result.from_json(json["Result"].to_json)
    if result.cancelled
      return task.try &.abort("request cancelled, #{result.code}: #{result.text}")
    end
    if !result.successful
      return task.try &.abort("request failed, #{result.code}: #{result.text}")
    end

    # Process response
    case json["Caption"].as_s
    when "AuthenticationResponseA"
      logged_in = json["LoggedIn"].as_bool
      self["authenticated"] = @authenticated = logged_in
      return task.try &.success if logged_in
      login(json["AuthenticationString"].as_s)
    when "AuthenticationResponseB"
      logged_in = json["LoggedIn"].as_bool
      self["authenticated"] = @authenticated = logged_in
      if logged_in
        logger.debug { "authentication success" }

        # Obtain the list of lockers and their current state
        query_lockers if @locker_ids.empty?
      else
        logger.warn { "authentication failure - please check credentials" }
      end
    when "GetLockersResponse"
      lockers = Array(Locker).from_json(json["Lockers"].to_json)
      lockers.each do |locker|
        locker_id = locker.id
        @locker_ids << locker_id
        if locker.locker_state != LockerState::Free
          @lockers_in_use << locker_id
          self["locker_#{locker_id}"] = locker.card_id
        else
          @lockers_in_use.delete(locker_id)
        end
      end
      self[:locker_ids] = @locker_ids
      self[:lockers_in_use] = @lockers_in_use
    when "CommandNotSupportedResponse"
      logger.warn { "Command not supported!" }
      return task.try &.abort("Command not supported!")
    end

    task.try &.success
  end

  private def parse_notify(caption, json)
    case caption
    when "LockerEventNotification"
      info = LockerNotification.from_json(json)
      update_locker_state(info.locker_state != LockerState::Free, info.locker.id, info.locker.card_id)
    else
      logger.debug { "ignoring event: #{caption}" }
    end
    nil
  end

  private def update_locker_state(in_use : Bool, locker_id : String, card_id : String) : Nil
    @locker_ids << locker_id
    if in_use
      @lockers_in_use << locker_id
    else
      @lockers_in_use.delete(locker_id)
    end
    self["locker_#{locker_id}"] = card_id
    self[:locker_ids] = @locker_ids
    self[:lockers_in_use] = @lockers_in_use
  end
end
