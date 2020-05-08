module ScreenTechnics; end

require "driver/interface/moveable"
require "driver/interface/stoppable"

# Documentation: https://aca.im/driver_docs/Screen%20Technics/Screen%20Technics%20IP%20Connect%20module.pdf
# Default user: Admin
# Default pass: Connect

class ScreenTechnics::Connect < PlaceOS::Driver
  include Interface::Moveable
  include Interface::Stoppable

  # Discovery Information
  descriptive_name "Screen Technics Projector Screen Control"
  generic_name :Screen
  tcp_port 3001

  COMMANDS = {
    up:     30,
    down:   33,
    status: 1, # this differs from the doc, but appears to work
    stop:   36,
  }

  CMD_LOOKUP = {
    30 => :up,
    33 => :down,
     1 => :status,
    36 => :stop,
  }

  def on_load
    # Communication settings
    queue.delay = 500.milliseconds
    transport.tokenizer = Tokenizer.new("\r\n")

    on_update
  end

  def on_update
    @count = setting?(Int32, :screen_count) || 1
  end

  def connected
    schedule.every(15.seconds, immediate: true) {
      (0...@count).each { |index| query_state(index) }
    }
  end

  def disconnected
    queue.clear
    schedule.clear
  end

  def move(position : MoveablePosition, index : Int32 | String = 0)
    index = index.to_i

    case position
    when MoveablePosition::Up
      up(index)
    when MoveablePosition::Down
      down(index)
    else
      raise "invalid position requested"
    end
  end

  def down(index : Int32 = 0)
    return if down?(index)
    stop(index)
    do_send :down, index, name: "direction#{index}"
    query_state(index)
  end

  def down?(index : Int32 = 0)
    {"moving_bottom", "at_bottom"}.includes?(self["screen#{index}"]?)
  end

  def up(index : Int32 = 0)
    return if up?(index)
    stop(index)
    do_send :up, index, name: "direction#{index}"
    query_state(index)
  end

  def up?(index : Int32 = 0)
    {"moving_top", "at_top"}.includes?(self["screen#{index}"]?)
  end

  def stop(index : Int32 | String = 0, emergency : Bool = false)
    index = index.to_i

    do_send(
      :stop, index,
      name: "stop#{index}",
      clear_queue: emergency,
      priority: emergency ? (queue.priority + 50) : queue.priority
    )
  end

  def query_state(index : Int32 = 0)
    do_send :status, index, 0x20
  end

  STATUS = {
     0 => :moving_top,
     1 => :moving_bottom,
     2 => :moving_preset_1,
     3 => :moving_preset_2,
     4 => :moving_top,    # preset top
     5 => :moving_bottom, # preset bottom
     6 => :at_top,
     7 => :at_bottom,
     8 => :at_preset_1,
     9 => :at_preset_2,
    10 => :stopped,
    11 => :error,
    # 12 => undefined
    13 => :error_timeout,
    14 => :error_current,
    15 => :error_rattle,
    16 => :at_bottom, # preset bottom
  }

  def received(data, task)
    data = String.new(data)
    logger.debug { "Screen sent #{data}" }

    # Builds an array of numbers from the returned string
    parts = data.split(/,/).map { |part| part.strip.to_i }
    cmd = CMD_LOOKUP[parts[0] - 100]?

    if cmd
      index = parts[2] - 17

      case cmd
      when :up
        logger.debug { "Screen#{index} moving up" }
        self["position#{index}"] = MoveablePosition::Up
        self["moving#{index}"] = true
      when :down
        logger.debug { "Screen#{index} moving down" }
        self["position#{index}"] = MoveablePosition::Down
        self["moving#{index}"] = true
      when :stop
        logger.debug { "Screen#{index} stopped" }
        self["moving#{index}"] = false
        screen = "screen#{index}"
        self[screen] = :stopped unless {"at_top", "at_bottom"}.includes?(self[screen]?)
      when :status
        self["screen#{index}"] = status = STATUS[parts[-1]]

        case status
        when :moving_top, :at_top
          self["position#{index}"] = MoveablePosition::Up
          self["moving#{index}"] = status == :moving_top
        when :moving_bottom, :at_bottom
          self["position#{index}"] = MoveablePosition::Down
          self["moving#{index}"] = status == :moving_bottom
        when :stopped
          self["moving#{index}"] = false
        when :error, :error_timeout, :error_current, :error_rattle
          self["moving#{index}"] = false
        end
      end

      task.try &.success
    else
      error = "Unknown command #{parts[0]}"
      logger.debug { error }
      task.try &.abort(error)
    end
  end

  protected def do_send(cmd, index = 0, *args, **options)
    address = index + 17
    parts = {COMMANDS[cmd], address} + args
    request = "#{parts.join(", ")}\r\n"
    send request, **options
  end
end
