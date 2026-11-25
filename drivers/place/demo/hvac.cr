require "placeos-driver"
require "placeos-driver/interface/powerable"

# Simulated HVAC unit for demos: no hardware and no transport.
# The temperature eases toward the setpoint, and an unoccupied room widens the
# target by `setback_offset` (occupancy setback).
class Place::Demo::HVAC < PlaceOS::Driver
  include Interface::Powerable

  descriptive_name "PlaceOS Demo HVAC"
  generic_name :HVAC
  description %(simulates an HVAC unit: temperature eases toward the setpoint \
with noise, exposes mode/fan/humidity/CO2/power, and applies occupancy setback. \
Accepts control commands. For demos. No hardware.)

  enum Mode
    Off
    Heat
    Cool
    Auto
  end

  enum Fan
    Auto
    Low
    Medium
    High
  end

  default_settings({
    initial_temperature: 22.5, # deg C
    setpoint:            21.5, # deg C
    mode:                "cool",
    fan:                 "auto",
    ambient_temperature: 28.0, # deg C the room drifts toward when not conditioning
    humidity:            50.0, # % relative humidity at start
    deadband:            0.4,  # deg C either side of the target
    tick_interval:       5,    # seconds between simulated samples
    occupancy_setback:   true,
    setback_offset:      3.0, # deg C
    occupied:            true,
  })

  @temperature : Float64 = 22.5
  @setpoint : Float64 = 21.5
  @ambient : Float64 = 28.0
  @humidity : Float64 = 50.0
  @co2 : Int32 = 500
  @deadband : Float64 = 0.4
  @mode : Mode = Mode::Cool
  @last_on_mode : Mode = Mode::Cool
  @fan : Fan = Fan::Auto
  @occupied : Bool = true
  @occupancy_setback : Bool = true
  @setback_offset : Float64 = 3.0
  @tick : Int32 = 5

  MIN_SETPOINT = 16.0
  MAX_SETPOINT = 30.0
  MIN_TEMP     = 10.0
  MAX_TEMP     = 40.0
  MIN_CO2      =  420
  MAX_CO2      = 1400

  # on_update is not called at startup when on_load is defined
  def on_load
    apply_settings
    @temperature = setting?(Float64, :initial_temperature) || @setpoint
    @occupied = setting?(Bool, :occupied) != false
    publish_state
    schedule.every(@tick.seconds) { simulate }
  end

  # Keeps the simulated temperature; only the tunables are re-read
  def on_update
    previous_tick = @tick
    apply_settings
    if previous_tick != @tick
      schedule.clear
      schedule.every(@tick.seconds) { simulate }
    end
    publish_state
  end

  private def apply_settings
    @setpoint = (setting?(Float64, :setpoint) || @setpoint).clamp(MIN_SETPOINT, MAX_SETPOINT)
    @ambient = setting?(Float64, :ambient_temperature) || @ambient
    @humidity = setting?(Float64, :humidity) || @humidity
    @deadband = setting?(Float64, :deadband) || @deadband
    @mode = Mode.parse(setting?(String, :mode) || @mode.to_s)
    @last_on_mode = @mode unless @mode.off?
    @fan = Fan.parse(setting?(String, :fan) || @fan.to_s)
    @occupancy_setback = setting?(Bool, :occupancy_setback) != false
    @setback_offset = setting?(Float64, :setback_offset) || @setback_offset
    @tick = setting?(Int32, :tick_interval) || @tick
  end

  # Returns the target temperature for this tick and whether setback applies.
  # Heating targets move down when empty, cooling targets move up.
  private def effective_target : {Float64, Bool}
    return {@ambient, false} if @mode.off?
    setback = @occupancy_setback && !@occupied
    return {@setpoint, false} unless setback
    if @mode.heat?
      {(@setpoint - @setback_offset).clamp(MIN_SETPOINT - 5, MAX_SETPOINT), true}
    else
      {(@setpoint + @setback_offset).clamp(MIN_SETPOINT, MAX_SETPOINT + 5), true}
    end
  end

  private def simulate
    target, setback = effective_target

    heating = !@mode.off? && !@mode.cool? && @temperature < target - @deadband
    cooling = !@mode.off? && !@mode.heat? && @temperature > target + @deadband
    conditioning = heating || cooling

    rate = conditioning ? 0.22 : 0.04
    noise = (rand - 0.5) * 0.2
    drift_target = conditioning ? target : @ambient
    @temperature = (@temperature + (drift_target - @temperature) * rate + noise).clamp(MIN_TEMP, MAX_TEMP)

    hnoise = (rand - 0.5) * 1.5
    hnoise -= 0.4 if cooling
    @humidity = (@humidity + hnoise).clamp(30.0, 70.0)

    if @occupied
      @co2 = (@co2 + 12 + rand(8)).clamp(MIN_CO2, MAX_CO2)
    else
      @co2 = (@co2 - 20).clamp(MIN_CO2, MAX_CO2)
    end

    publish_state(heating, cooling, setback)
  end

  # 0 = off, 1 = low, 2 = medium, 3 = high
  private def running_fan_level(conditioning : Bool) : Int32
    return 0 if @mode.off?
    return @fan.value if @fan != Fan::Auto
    return 1 unless conditioning
    diff = (@setpoint - @temperature).abs
    diff < 1.0 ? 2 : 3
  end

  # Watts
  private def power_draw(heating : Bool, cooling : Bool, fan_level : Int32) : Int32
    watts = fan_level * 120
    watts += 2800 if cooling
    watts += 2400 if heating
    watts
  end

  private def publish_state(heating : Bool = false, cooling : Bool = false, setback : Bool = false)
    fan_level = running_fan_level(heating || cooling)
    self[:temperature] = @temperature.round(1)
    self[:setpoint] = @setpoint.round(1)
    self[:mode] = @mode.to_s.downcase
    self[:fan] = @fan.to_s.downcase
    self[:fan_level] = fan_level
    self[:fan_running] = fan_level > 0
    self[:humidity] = @humidity.round(0).to_i
    self[:co2] = @co2
    self[:occupied] = @occupied
    self[:heating] = heating
    self[:cooling] = cooling
    self[:setback_active] = setback
    self[:power_draw] = power_draw(heating, cooling, fan_level)
    self[:power] = !@mode.off?
    self[:connected] = true
    self[:last_updated] = Time.utc.to_unix
  end

  # On restores the last mode other than off
  @[Security(Level::Support)]
  def power(state : Bool)
    @mode = state ? @last_on_mode : Mode::Off
    simulate
    state
  end

  @[Security(Level::Support)]
  def set_temperature(value : Float64)
    @setpoint = value.clamp(MIN_SETPOINT, MAX_SETPOINT)
    simulate
    @setpoint
  end

  @[Security(Level::Support)]
  def set_mode(mode : Mode)
    @mode = mode
    @last_on_mode = mode unless mode.off?
    simulate
    @mode.to_s.downcase
  end

  @[Security(Level::Support)]
  def set_fan(speed : Fan)
    @fan = speed
    simulate
    @fan.to_s.downcase
  end

  @[Security(Level::Support)]
  def set_occupied(state : Bool)
    @occupied = state
    simulate
    @occupied
  end

  def state
    {
      temperature:    @temperature.round(1),
      setpoint:       @setpoint.round(1),
      mode:           @mode.to_s.downcase,
      fan:            @fan.to_s.downcase,
      humidity:       @humidity.round(0).to_i,
      co2:            @co2,
      occupied:       @occupied,
      setback_active: @occupancy_setback && !@occupied && !@mode.off?,
    }
  end
end
