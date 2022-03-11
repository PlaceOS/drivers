require "placeos-driver"
require "./nvx_models"

class Crestron::NvxScalerControl < PlaceOS::Driver
  descriptive_name "Crestron NVX Scaler Control"
  generic_name :NvxAddressManager

  description <<-DESC
    Synconisation tool for managing scaling settings on NVX decoders based
    on window aspect ratios of a videowall processor.

    To enable flexible / user selectable distribution of both 16:9 and 21:9
    signals, aspect ratio control across both the videowall processor and
    NVX decoders is exploited to keep things looking nice.

    In the case a decoder is being displayed on a 16:9 window it is set to
    scale-to-fit, enabling ultrawide signals to be letterboxed. When a
    signal is being send to an ultrawide window it is instead set to
    scale-to-fill (stretch) on the NVX, then a second level of distortion
    is applied on the videowall processor to convert this back to it's
    original aspect.

    This approach keeps all components of the signal chain at 1080p / 4K and
    enables live switching all all sources without EDID re-negotation.
  DESC

  default_settings({
    # Mapping of { <window id>: <nvx mod> }
    link_scalers: {
      window_1: "Decoder_1",
      window_2: "Decoder_2",
    },
  })

  @links : Hash(String, String) = {} of String => String

  # Window of aspect ratio's to detect as 16:9 - allows for +/-5% for
  # slightly off-shape windows
  SCALE_TO_FIT_BOUNDS = (16 / 9 * 0.95)..(16 / 9 * 1.05)

  def on_load
    on_update
  end

  def on_update
    @links = setting?(Hash(String, String), :link_scalers) || {} of String => String
  end

  bind VideoWall_1, :windows, :videowall_windows_changed

  private def videowall_windows_changed(_subscription, new_value)
    windows = Hash(String, NamedTuple(canwidth: Float64, canheight: Float64)).from_json new_value
    windows.each do |id, props|
      next unless @links.has_key? id

      nvx = system.get @links[id]

      aspect_ratio = props[:canwidth] / props[:canheight]

      if aspect_ratio.nan?
        logger.debug { "#{id} not positioned on canvas, skipping" }
      elsif SCALE_TO_FIT_BOUNDS.includes? aspect_ratio
        logger.debug { "detected #{id} as 16:9, maintaining aspect" }
        nvx.aspect_ratio AspectRatio::MaintainAspectRatio
      else
        logger.debug { "detected #{id} as ultrawide, filling window" }
        nvx.aspect_ratio AspectRatio::StretchToFit
      end
    end
  end
end
