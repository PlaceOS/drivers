# How to test a PlaceOS Driver

There are three kinds of PlaceOS Driver...

* [Streaming IO (TCP, SSH, UDP, Multicast, etc.)](#testing-streaming-io)
* [HTTP Client](#testing-http-requests)
* [Logic](#testing-logic)

From a PlaceOS Driver code structure standpoint, there is no difference between these types of Driver.

* The same driver can be used over a TCP, UDP or SSH transport.
* All drivers support HTTP methods if a URI endpoint is defined.
* If a driver is associated with a System then it has access to logic helpers

During a test, the loaded module is loaded with a TCP transport, HTTP enabled and logic module capabilities.
This allows for testing the full capabilities of any driver.

The driver is launched as it would be in production.


## Expectations

Specs have access to Crystal lang spec expectations. This allows you to confirm expectations.
https://crystal-lang.org/api/latest/Spec/Expectations.html

```crystal

variable = 34
variable.should eq(34)

```

There is a good overview on how to use expectations here: https://crystal-lang.org/reference/guides/testing.html


### Status

Expectations are primarily there to test the state of the module.

* You can access state via the status helper: `status[:state_name]`
* Then you can check it an expected value: `status[:state_name].should eq(14)`


## Testing Streaming IO

The following functions are available for testing streaming IO:

* `transmit(data)` -> transmits the object to the module over the streaming IO interface
* `responds(data)` -> alias for `transmit`
* `should_send(data, timeout = 500.milliseconds)` -> expects the module to respond with the data provided
* `expect_send(timeout = 500.milliseconds)` -> returns the next `Bytes` sent by the module (useful if the data sent is not deterministic, i.e. has a time stamp)

A common test case is to ensure that module state updates as expected after transmitting some data to it:

```crystal

# Transmit some data
transmit(">V:2,C:11,G:2001,B:1,S:1,F:100#")

# Check that the state was updated as expected
status[:area2001].should eq(1)

```


## Testing HTTP requests

The test suite emulates an HTTP server so you can inspect HTTP requests and send canned responses to the module.

```crystal

expect_http_request do |request, response|
  io = request.body
  if io
    data = io.gets_to_end
    request = JSON.parse(data)
    if request["message"] == "hello steve"
      response.status_code = 202
    else
      response.status_code = 401
    end
  else
    raise "expected request to include dialing details #{request.inspect}"
  end
end

# Check that the state was updated as expected
status[:area2001].should eq(1)

```

Use `expect_http_request` to access an expected request coming from the module.

* When the block completes, the response is sent to the module
* You can see `request` object details here: https://crystal-lang.org/api/latest/HTTP/Request.html
* You can see `response` object details here: https://crystal-lang.org/api/latest/HTTP/Server/Response.html


## Executing functions

Functions allow you to request methods to be performed in the module via the standard public interface.

* `exec(:function_name, argument_name: argument_value)` -> `response` a response future (async return value)
* You should send and `responds(data)` before inspecting the `response.get`

```crystal

# Execute a command
response = exec(:scene?, area: 1)

# Check that the command causes the module to send some data
should_send("?AREA,1,6\r\n")
# Respond to that command
responds("~AREA,1,6,2\r\n")

# Check if the functions return value is expected
response.get.should eq(2)
# Check if the module state is correct
status[:area1].should eq(2)

```


## Testing Logic

Logic modules typically expect a system to contain some drivers which the logic modules interact with.

```crystal

# define mock versions of the drivers it will interact with

class Display < DriverSpecs::MockDriver
  include Interface::Powerable
  include Interface::Muteable

  enum Inputs
    HDMI
    HDMI2
    VGA
    VGA2
    Miracast
    DVI
    DisplayPort
    HDBaseT
    Composite
  end

  include PlaceOS::Driver::Interface::InputSelection(Inputs)

  # Configure initial state in on_load
  def on_load
    self[:power] = false
    self[:input] = Inputs::HDMI
  end

  # implement the abstract methods required by the interfaces
  def power(state : Bool)
    self[:power] = state
  end

  def switch_to(input : Inputs)
    mute(false)
    self[:input] = input
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    self[:mute] = state
    self[:mute0] = state
  end
end

```

Then you can define the system configuration,
you can also change the system configuration throughout your spec to test different configurations.

```crystal

DriverSpecs.mock_driver "Place::LogicExample" do

  # Where `{Display, Display}` is referencing the `MockDriver` class defined above
  # and `Display:` is the friendly name
  # so this system would have `Display_1`, `Display_2`, `Switcher_1`
  system({
    Display:  {Display, Display},
    Switcher: {Switcher},
  })

  # ...
end

```

Along with the physical system configuration, you can test different setting configurations.
Settings can also be changed throughout the life cycle of your spec.

```crystal

DriverSpecs.mock_driver "Place::LogicExample" do

  settings({
    name: "Meeting Room 1",
    map_id: "1.03"
  })

end

```

A Driver's method might be expected to update some state in the mock devices.
You can access this state via the `system` helper

```crystal

DriverSpecs.mock_driver "Place::LogicExample" do

  # Execute a function in your logic module
  exec(:power, true)

  # Check that the expected state has been updated in your mock device
  system(:Display_1)[:power].should eq(true)

end

```

All status queried in this manner is returned as a `JSON::Any` object
