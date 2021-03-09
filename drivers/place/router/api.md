# Functions

## `route(input, output)`
Performs all intermiedate device interaction required to route a signal between two points.
Supports specifying either local i/o aliases (see settings), or node ref's.

## `mute(input_or_output, state = true)`
Activates or deactivates a signal mute for the associated IO.
If this is not possible, (e.g. unsupported by the device) an error is returned.

## `unmute(input_or_output)`
Deactivates signal mute for the passed IO.

## `lock(input_or_output)`
Locks an IO node.
Prevents any route changes that include this until unlocked.

## `unlock(input_or_output)`
Unlocks a signel node.

# Status

## `inputs`
Provides a list of the input aliases currently available to the system.
```json
[ "foo", "bar" ]
```

## `input/<alias>`
Provides a hash of status information for the associated input alias.
```json
{
  "name": "human friendly name",
  "type": "input type as specified in settings",
  "module": "id of the module that provides control (if applicable)",
  "mute": false,
  "locked": false,
  "routes": ["list of output current using this input"],
  "outputs": ["list of reachable output aliases"]
}
```

## `outputs`
Provides a list of the output aliases currently available to the system.
```json
[ "baz", "qux" ]
```

## `output/<alias>`
Metadata and state infor for the associated output.
```json
{
  "name": "human friendly name",
  "type": "input type as specified in settings",
  "module": "id of the module that provides control (if applicable)",
  "mute": false,
  "locked": false,
  "source": "alias of input currently feeding this",
  "inputs": ["list of reachable input aliases"],
  "following": "alt output alias this is following"
}
```

# Settings

## `connections`
```json
[
  "switcher{1} -> {hdmi}display_1",
  "switcher{2} -> {hdmi}display_2",
  "switcher{3} -> {hdmi}VidConf",
  "switcher_2 -> {1}switcher_1",
  "camera_1 -> {2}switcher_1",
  "camera_2 -> {3}switcher_1"
]
```

## `inputs`
Defines signal sources used by the system.
```json
{
  "<alias>": {
    "ref": "associated signal node ref - e.g. {1}switcher_1",
    "name": "a readable name",
    "type": "TBA - one of an enum - e.g. laptop, camera, VC, mic"
  }
}
```
Or compact form:
```json
{
  "<alias>": "<ref>"
}
```

## `outputs`
Defined signal outputs used by the system.
```json
{
  "<alias>": {
    "ref": "associated signal node ref - e.g. display_1",
    "name": "a readable name",
    "type": "TBA - one of an enum - e.g. lcd, projector, recorder, stream"
  }
}
```
Or compact form:
```json
{
  "<alias>": "<ref>"
}
```
