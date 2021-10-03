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

  default_settings({
    sync_with: "Display_1",
  })

  def on_load
    schedule.every(1.minute) { status }
    on_update
  end

  def on_update
    sync_with = setting?(String, :sync_with)
    subscriptions.clear
    if sync_with
      subscription = system.subscribe(sync_with, :power) do |_sub, power_state|
        if power_state && power_state != "null"
          power_state == "true" ? up : down
        end
      end
    end
  end

  # moveable interface
  def move(position : MoveablePosition, index : Int32 | String = 0)
    response = case position
               when .up?, .close?, .in?
                 get("/Close.js?a=100")
               when .down?, .open?, .out?
                 get("/Open.js?a=100")
               else
                 raise "unsupported move option: #{position}"
               end

    self[:status] = parse_state StatusResp.from_json(response.body).status
  end

  # stoppable interface
  def stop(index : Int32 | String = 0, emergency : Bool = false)
    response = get("/Stop.js?a=100")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
    self[:status] = parse_state StatusResp.from_json(response.body).status
  end

  def status : AmberTech::Devices
    response = get("/GetDevInfoList.js")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
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
    schedule.every(1.minute) { status }
    schedule.in(2.seconds) { status }
  end
end
