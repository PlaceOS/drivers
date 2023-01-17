require "placeos-driver"

class Place::Router < PlaceOS::Driver
  generic_name :Switcher
  descriptive_name "Signal router"
  description <<-DESC
    A virtual matrix switcher for arbitrary signal networks.

    Following configuration, this driver can be used to perform simple input → \
    output routing, regardless of intermediate hardware. Drivers it interacts \
    with _must_ implement the `Switchable`, `InputSelection` or `Muteable` \
    interfaces.

    Configuration is specified as a map of devices and their attached inputs. \
    This must exist under a top-level `connections` key.

    Inputs can be either named:

        Display_1:
          hdmi: VidConf_1

    Or, index based:

        Switcher_1:
          - Camera_1
          - Camera_2

    If an input is not a device with an associated module, prefix with an \
    asterisk (`*`) to create a named alias.

        Display_1:
          hdmi: *Laptop

    DESC
end

require "./router/core"

class Place::Router < PlaceOS::Driver
  include Core
end
