# How to write a spec

There are three kind of drivers

* Streaming IO (TCP, SSH, UDP, Multicast, ect)
* HTTP Client
* Logic

From a driver code structure standpoint there is no difference between these types.

* The same driver can be used over a TCP, UDP or SSH transport.
* All drivers support HTTP methods if a URI endpoint is defined.
* If a driver is associated with a System then it has access to logic helpers

During a test, the loaded module is loaded with a TCP transport, HTTP enabled and logic module capabilities.
This allows for testing the full capabilities of any driver.

The driver is lunched as it would be in production.


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

A common test case is to ensure that module state updates as expected after transmitting some data to it:

```crystal

# transmit some data
transmit(">V:2,C:11,G:2001,B:1,S:1,F:100#")

# check that the state updated as expected
status[:area2001].should eq(1)

```


## Testing HTTP requests

The test suite emulates a HTTP server so you can inspect HTTP requests and send canned responses to the module.

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

# check that the state updated as expected
status[:area2001].should eq(1)

```

Use `expect_http_request` to access an expected request coming from the module.

* when the block completes, the response is sent to the module
* you can see `request` object details here: https://crystal-lang.org/api/0.29.0/HTTP/Request.html
* you can see `response` object details here: https://crystal-lang.org/api/0.29.0/HTTP/Server/Response.html


## Executing functions

This allows you to request actions be performed in the module via the standard public interface.

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

TODO:: helpers for mocking out complex systems is coming in a future update.

* Defining system configuration
* Mocking remote module functions and state
* Tracking remote function calls
