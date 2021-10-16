# Meet Readme

Docs on how to configure a tabbed control UI

* available icons for controls are: https://fonts.google.com/icons?selected=Material+Icons

## Routing

The router is designed to graph signal paths in a system between devices.
https://docs.google.com/document/d/1DG2s9jjMVhiW65YGPDkUnOYYpFDeW42SkGvHyp1BEjQ/

* devices can be represented by modules `Display_1`
* virutal devices can be representated by a `*`: `*Laptop_HDMI`

Connections are then defined by a flat map of Output => Inputs
There are two styles of switching supported:

* `switch_to`: an output that multiple inputs
* `switch`: multiple outputs and multiple inputs

NOTE:: when an input is presented to an output via `route("Input_id", "Output_id")`
if the input and output support the `Powerable` interface, they will be powered on


### Examples

A basic single display system

```yaml

# A switch_to style of output where the inputs are virtual devices
# virtual devices as no modules in the system represent the inputs
connections:
  Display_1:
    hdmi: '*HDMI_Cable'
    hdmi2: '*Wireless_Presenter'

```

A switcher and multiple displays

* Switcher outputs are represented by `.` i.e. `Switcher_1.2` (output 2)
* Switcher inputs can be represented by `:` i.e. `Switcher_1:2` (input 2)
  * Switcher inputs in this format are only required if chaining multiple switchers

```yaml

# A typical single switcher setup
connections:
  # Display 1 is connected to Switcher 1 ouput 1
  Display_1:
    hdmi: Switcher_1.1
  Display_2:
    hdmi: Switcher_1.2

  # We have a virtual output connected to output 5
  '*AUX_Output': Switcher_1.5

  # The switcher inputs are hooked up using a hash
  Switcher_1:
    '1': '*Wireless_Presenter' # always on, wireless presenter
    '2': IPTV_1         # set top box or streaming input that can be powered on
    '5': '*Desk_HDMI_1' # i.e. laptop inputs on a table in the room
    '6': '*Desk_HDMI_2'

```

If you have a situation where audio and video need to be switched separately then you can also define layers on the switcher outputs.

```yaml

# A weird audio setup
connections:
  # Front of house audio split from the camera video input (real world example!)
  Display_1:
    hdmi: Switcher_1.12
  '*VC_Camera_1': Switcher_1.1!video
  '*FOH_Audio': Switcher_1.1!audio

  # The switcher inputs are hooked up using a hash
  Switcher_1:
    '1': '*Wireless_Presenter' # always on, wireless presenter
    '2': IPTV_1         # set top box or streaming input that can be powered on
    '5': '*Desk_HDMI_1' # i.e. laptop inputs on a table in the room
    '6': '*Desk_HDMI_2'

# as we also want the audio to follow anything being presented to the display
# you can ensure the sources follow one another
outputs:
  Display_1:
    name: Projector
    followers: ["FOH_Audio"]

```


### Default routes

these are applied at system startup

```yaml

# output id => input id (as defined in the router)
default_routes:
  VC_Camera_1: Camera_1
  VC_Camera_2: Camera_2

```


## Naming Inputs and Outputs

Inputs and outputs are all referenced from their IDs which are either:

* DeviceMod_1
* Virtual_Device

However you can apply metadata to these inputs and outputs, such as name for display on the user interface. This configuration is split between the inputs and outputs.

```yaml

# Input meta data
inputs:
  Desk_HDMI_1:
    name: Table Box HDMI Cable
    icon: input
  Wireless_Presenter:
    name: Wireless
    icon: connected_tv

  # Inputs of type cam are collected for camera control
  # index is optional (only where a single module controls multiple cameras)
  Camera_1:
    name: Camera 1
    icon: video_camera_front
    type: cam
    mod: Camera_1
    index: 1

  # Inputs that have `presentable: false` are ignored as possible inputs for VC presenations
  VidConf_1:
    name: Video Conference
    icon: video_camera_front
    presentable: false

```

Output config is typically less interesting

```yaml

outputs:
  Display_1:
    name: Display Left
  Display_2:
    name: Display Right

```


## Laying out Tabs

Spaces can have more inputs and outputs defined then you want to display on the panel. Some things are auto switched etc so you need define you tab layouts.

```yaml

# a single tab UI with the optional help link
tabs:
  - name: Laptop
    icon: computer
    help: laptop-help

    # Multiple inputs can be on a single tab
    inputs:
      - HDMI_Cable
      - Wireless_Presenter

```


### Cisco Video Conferencing

Configuring a tab with Cisco VC controls

```yaml

tabs:
  - name: Conference
    icon: video_camera_front
    # The controls we want to see on the tab
    controls: vidconf-controls
    # this defines the switch output representing the presentation input on the VC
    presentation_source: Virtual_VC_Presentation_Ouput
    inputs:
      - VidConf_1

```


### IPTV Control

Configuring IPTV controls for a page

```yaml

tabs:
  - name: TV
    icon: live_tv

    # the controls we want to show (expects IPTV_1 mod to expose channel details)
    controls: tv-channels
    mod: IPTV_1
    inputs:
      - IPTV_1

```

example channel detail config (see [Exterity M93xx](https://github.com/PlaceOS/drivers/blob/master/drivers/exterity/avedia_player/m93xx.cr#L15) for an example driver)

```yaml
channel_details:
  - name: Al Jazeera
    channel: 'udp://239.192.10.170:5000?hwchan=0'
    icon: 'https://os.place.tech/placeos.com/16335767803641925864.svg'
```


## Help pages

This is custom HTML content that is embedded on the UI.
The help key (`laptop-help` in the example below) is used to link the help to a tab

* Help pages are inlined onto tabs when there are no controls defined.
* Where there are controls defined a button is placed on the tab that links to the help pop-up

```yaml

help:
  laptop-help:
    title: Swytch
    icon: computer
    content: >
      Follow the instructions below on how to connect your laptop in a meeting
      room:

      1. Plug the ‘Y’ shaped connector into the USB-C port on your laptop.

      <img
      src="https://os.place.tech/placeos.pwc.com.au/1632888427183509679.png"
      alt="Swytch" title="Swytch help" style="max-width: 760px" />


```

You can drag and drop images and videos into backoffice so they are available for embedding.


## Defining Outputs to display

You need to define which ouputs will be displayed on the panel.

* when there is a single output, it'll automatically be switched
* where there are two outputs, the user must manually switch by selecting the output

```yaml

# named local outputs as when joining rooms we'll merge these with joined rooms
local_outputs:
  - Display_1
  - Display_2

```

Where you have Preview Monitor(s) for previewing sources before presenting them, you configure them using:

```yaml

# these will show the currently selected input
preview_outputs:
  - Display_3

```


## Front of House Audio

By default the first display in the output list is assumed to be managing audio
However you may want to configure defaults or use Mixer controls instead of the output device

```yaml

# This is a mixer configuration
master_audio:
  name: FOH Speakers
  level_id: ["FOH-1234", "FOH-1235"]
  mute_id: 'FOH-123-45-mute'

  level_index: 4,
  mute_index: 4,
  level_feedback: 'faderFOH-1234'
  mute_feedback: 'faderFOH-1234_mute'
  module_id: 'Mixer_2'

  default_muted: false
  default_level: 60

  min_level: 40
  max_level: 90

```

You can just customise defaults if you want to continue using the default output

```yaml

master_audio:
  default_muted: false
  default_level: 60

```


## Projector Screen Linking

Linking a projector screen to a displays power state

```yaml

screens:
 Karijini_IV_Projector_1: Screen_1

```

## QSC Phone Dialing controls

The places a dialing phone icon at the top of the screen that can be used to dial a phone number. Does not effect other aspects of the UI / Switching.

```yaml

phone_settings:
    module: "Mixer_1",
    number_id: "Status/Control16-17-VoIPCallControlDialString",
    dial_id: "Status/Control16-17-VoIPCallControlConnect",
    hangup_id: "Status/Control16-17-VoIPCallControlDisconnect",
    status_id: "Status/Control16-17-VoIPCallStatusProgress",
    ringing_id: "Status/Control16-17-VoIPCallStatusRinging(state)",
    offhook_id: "Status/Control16-17-VoIPCallStatusOffHook",
    dtmf_id: "16.17:dtmftx1"

```

Then in the QSC driver you want to define which controls QSC should poll and report changes:

```yaml

# keeps the phone status in sync
change_groups: {
  "room123_phone" => {
    id:       1,
    controls: ["VoIPCallStatusProgress", "VoIPCallStatusRinging", "VoIPCallStatusOffHook"],
  },
},

```


## Microphone configuration

A basic list of fader and mute values that represent the microphones available

```yaml

local_microphones:
  - name: Hand Held Microphone
    level_id: ["HH-1234", "HH-1235"]
    mute_id: 'HH-123-45-mute'

    # optional keys
    level_index: 4,
    mute_index: 4,
    level_feedback: 'faderHH-1234'
    mute_feedback: 'faderHH-1234_mute'
    module_id: 'Mixer_2'

    default_muted: true
    default_level: 55.8

    min_level: 40
    max_level: 90

```
