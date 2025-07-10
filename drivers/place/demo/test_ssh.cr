require "placeos-driver"

class Place::Demo::TestSSH < PlaceOS::Driver
  # Discovery Information
  descriptive_name "SSH Testing Tool"
  generic_name :TestSSH
  tcp_port 22

  default_settings({
    ssh: {
      username: :root,
      password: :password,
    },
  })

  def ls(dir : String = "./", modifiers : String = "")
    exec("ls -#{modifiers} #{dir}").gets_to_end
  end

  def run(command : String, wait : Bool = true)
    logger.debug { "SSH command:\n#{command}" }
    send "#{command}\n", wait: wait
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "SSH response:\n#{data}" }
    task.try &.success(data)
  end
end
