require "placeos-driver"

class TvOne::WindowStacker < PlaceOS::Driver
  descriptive_name "Videowall Window Stacker Logic"
  generic_name :WindowStacker

  description <<-DESC
    The CORIOmaster videowall processors does not provide the ability to hide
    windows on signal loss. This logic module may be used to bind windows used
    in a layout to displays defined within a system. When a display has no source
    routed it's Z-index will be dropped to 0, revealing background content.

    Use settings to define mapping between system outputs and window ID's:
    ```
    {
        "windows": {
            "Display_1": [1, 2, 3],
            "Display_2": 7,
            "Display_3": [9, 4]
        }
    }
    ```
  DESC

  default_settings({
    show_z_index: 15,
    hide_z_index: 0,
    videowall:    "VideoWall_1",
    windows:      {
      "Display_1" => [1, 2, 3],
      "Display_2" => 7,
      "Display_3" => [9, 4],
    },
  })

  @subscriptions : Array(::PlaceOS::Driver::Subscriptions::IndirectSubscription) = [] of PlaceOS::Driver::Subscriptions::IndirectSubscription
  @videowall : String = "VideoWall_1"
  @show : Int32 = 15
  @hide : Int32 = 0

  def on_update
    clear_subscriptions

    bindings = setting?(Hash(String, Int32 | Array(Int32)), :windows) || {} of String => Int32 | Array(Int32)
    @videowall = setting?(String, :videowall) || "VideoWall_1"
    @show = setting?(Int32, :show_z_index) || 15 # visible z layer
    @hide = setting?(Int32, :hide_z_index) || 0  # hidden z layer

    # Subscribe to source updates and relayer on change
    sys = system[:System_1]
    @subscriptions = bindings.map do |display, window|
      sys.subscribe("output/#{display}") do |_sub, value|
        logger.debug { "Restacking #{display} linked windows due to source change" }
        source = JSON.parse(value)["source"]?.try(&.as_s?)
        restack window, source
      end
    end

    # Also restack after a videowall preset recall
    @subscriptions << system[@videowall].subscribe("preset") do |_sub, notice|
      logger.debug { "Restacking all videowall windows due to preset change" }
      bindings.each do |display, window|
        begin
          source = system[:System][display]["source"]?.try(&.as_s?)
          restack window, source
        rescue
          logger.warn { "could not find active source for #{display}" }
        end
      end
    end
  end

  protected def clear_subscriptions
    logger.debug { "clearing subscriptions!" }
    @subscriptions.each { |sub| subscriptions.unsubscribe(sub) }
    @subscriptions.clear
  end

  protected def restack(window : Int32 | Array(Int32), source : String?)
    window = window.is_a?(Array) ? window : [window]
    wall_controller = system[@videowall]

    z_index = {nil, "MUTE"}.includes?(source) ? @hide : @show
    window.each do |id|
      wall_controller.window id, "Zorder", z_index
    end
  end
end
