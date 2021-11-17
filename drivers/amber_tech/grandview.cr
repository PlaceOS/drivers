require "placeos-driver"
require "placeos-driver/interface/moveable"
require "placeos-driver/interface/stoppable"

# Documentation: https://aca.im/driver_docs/AmberTech/grandview-screen.pdf
# https://www.ambertech.com.au/Documents/GV_IP%20CONTROL_Smart%20Screen_Trifold_Manual_April2020.pdf
require "./grandview_models"

class AmberTech::Grandview < PlaceOS::Driver
  include Interface::Moveable
  include Interface::Stoppable

  # Discovery Information
  generic_name :Screen
  descriptive_name "Ambertech Grandview Projector Screen"
  uri_base "http://192.168.0.2"

  def on_load
    queue.delay = 500.milliseconds
    schedule.every(1.minute) { status }
  end

  # moveable interface
  def move(position : MoveablePosition, index : Int32 | String = 0)
    command = case position
              when .up?, .close?, .in?
                "/Close.js?a=100"
              when .down?, .open?, .out?
                "/Open.js?a=100"
              else
                raise "unsupported move option: #{position}"
              end

    queue(name: "move") do |task|
      response = get(command)
      raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
      self[:status] = status = parse_state StatusResp.from_json(response.body).status
      task.success status
    end
  end

  # stoppable interface
  def stop(index : Int32 | String = 0, emergency : Bool = false)
    queue(name: "stop", priority: 999, clear_queue: emergency) do |task|
      response = get("/Stop.js?a=100")
      raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

      self[:status] = status = parse_state StatusResp.from_json(response.body).status
      task.success status
    end
  end

  def status
    if queue.online
      queue(name: "status", priority: 0) do |task|
        response = perform_status_request
        if response.success?
          task.success parse_status(response)
        else
          task.abort "request failed with #{response.status_code}\n#{response.body}"
        end
      end
    else
      response = perform_status_request
      parse_status(response) if response.success?
    end
  end

  protected def perform_status_request
    get("/GetDevInfoList.js")
  end

  protected def parse_status(response)
    info = AmberTech::Devices.from_json(response.body)
    state = info.device_info.first

    self[:ver] = state.ver
    self[:id] = state.id
    self[:ip] = state.ip
    self[:ip_subnet] = state.ip_subnet
    self[:ip_gateway] = state.ip_gateway
    self[:name] = state.name
    self[:status] = parse_state state.status
    info
  end

  # compatibility with Screen Technics
  def up(index : Int32 = 0)
    move :up
  end

  def up?
    {"opened", "opening"}.includes?(self["status"]?)
  end

  def down(index : Int32 = 0)
    move :down
  end

  def down?
    {"closed", "closing"}.includes?(self["status"]?)
  end

  protected def parse_state(state : AmberTech::Status)
    case state
    in .stop?
      self[:moving0] = false
      self[:position0] = nil
      self[:screen0] = "stopped"
    in .opening?
      self[:moving0] = true
      self[:position0] = MoveablePosition::Open
      self[:screen0] = "moving_bottom"
      poll_state
    in .opened?
      self[:moving0] = false
      self[:position0] = MoveablePosition::Open
      self[:screen0] = "at_bottom"
    in .closing?
      self[:moving0] = true
      self[:position0] = MoveablePosition::Close
      self[:screen0] = "moving_top"
      poll_state
    in .closed?
      self[:moving0] = false
      self[:position0] = MoveablePosition::Close
      self[:screen0] = "at_top"
    end

    state.to_s.downcase
  end

  protected def poll_state
    schedule.clear
    schedule.every(1.minute) { status; nil }
    schedule.in(2.seconds) { status; nil }
  end
end
