# TODO: figure out if I should use this
# require "placeos-driver/interface/muteable"

# https://q-syshelp.qsc.com/Content/External_Control/Q-SYS_External_Control/007_Q-SYS_External_Control_Protocol.htm

class Qsc::QSysRemote < PlaceOS::Driver
  # include Interface::Muteable

  # Discovery Information
  tcp_port 1710
  descriptive_name "QSC Audio DSP"
  generic_name :Mixer

  @id : Int32 = 0

  JsonRpcVer = "2.0"
  Delimiter = "\0"

  def on_load
    transport.tokenizer = Tokenizer.new(Delimiter)
    on_update
  end

  def on_update
    # @db_based_faders = setting(:db_based_faders)
    # @integer_faders = setting(:integer_faders)
  end

  def connected
    schedule.every(20.seconds) do
      logger.debug { "Maintaining Connection" }
      no_op
    end
    @id = 0
    logon
  end

  def disconnected
    schedule.clear
  end

  def no_op
    do_send(cmd: :NoOp, priority: 0)
  end

  def get_status
    do_send(next_id, cmd: :StatusGet, params: 0, priority: 0)
  end

  def logon(username : String? = nil, password : String? = nil)
    username ||= setting?(String, :username)
    password ||= setting?(String, :password)
    # Don't login if there is no username or password set
    return unless username || password

    do_send(
      cmd: :Logon,
      params: {
        :User => username,
        :Password => password
      },
      priority: 99
    )
  end

  def received(data, task)
  end

  def next_id
    @id += 1
    @id
  end

  private def do_send(id : Int32? = nil, cmd = nil, params = {} of String => String, **options)
    if id
      req = {
        id: id,
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    else
      req = {
        jsonrpc: JsonRpcVer,
        method: cmd,
        params: params
    }
    end

    logger.debug { "requesting: #{req}" }

    cmd = req.to_json + Delimiter

    send(cmd, **options)
  end
end
