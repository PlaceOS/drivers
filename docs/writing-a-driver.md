# Writing A Driver

There are three main uses of drivers:

* Streaming IO (TCP, SSH, UDP, Multicast etc.)
* HTTP Client
* Logic

From a driver structure standpoint there is no difference between these types.

* The same driver works over a TCP, UDP or SSH transport
* All drivers support HTTP methods (except logic modules)
  * for example a websocket driver or tcp driver will also be provided a default HTTP client at the base URI of the websocket and IP address of the tcp driver.
  * this default client URL can be overwritten, for example where the [HTTP port](https://github.com/PlaceOS/drivers/blob/master/drivers/aver/cam520_pro.cr#L43-L45) is different to the websocket port\
    `transport.http_uri_override = URI.new`
* All drivers have access to logic helpers when associated with a System

### Code documentation

For detailed automatically generated documentation please see the: [Driver API](https://placeos.github.io/driver/PlaceOS/Driver.html)

1. All drivers should require placeos-driver before anything else.
2. There should be a single class that inherits \`PlaceOS::Driver\`

```crystal
require "placeos-driver"
require "..."

class MyDriver < PlaceOS::Driver
  ...
end
```

### Lifecycle

All PlaceOS Drivers have a lifecycle that is managed by the system.

There are 5 lifecycle events:

* `#on_load` - Called when a driver instance (a module) is started.
* `#on_update` - Called when settings are updated or on start if on_load is not defined
* `#on_unload` - Called when a module is stopped.
* `#connected` - Called when the TCP/UDP/SSH transport has established a connection.
* `#disconnected` - Called when a connection is lost or a connection failure occurs (unable to connect). Whilst connections will continually attempt to be established, this is only called on state changes. So the first failed connection attempt or state change from connected to disconnected.

### Queue

The queue is a list of potentially asynchronous tasks that should be performed in a sequence.

* Each task has a priority (defaults to `50`) - higher priority tasks run first
* Tasks have names - if there's a name conflict, the newer task overwrites the older one
* Tasks have a timeout (defaults to `5.seconds`)
* Tasks a set amount of re-tries (defaults to `3` before failing)

Tasks have a callback which can run the task

```crystal
# => you can set queue defaults globally

# set a delay between the current task completing and the next task
queue.delay = 1.second
queue.retries = 5

queue(priority: 20, timeout: 1.second) do |task|
  # perform action here

  # signal result
  task.success("optional success value")
  task.abort("optional failure message")
  task.retry

  # Give me more time to complete the task
  task.reset_timers
end
```

In most cases you won't need to use the queue explicitly, but it's good to understand that how it functions.

### Transport

The transport loaded is defined by settings in the database.

#### Streaming IO

You should always tokenize your streams. You can do this automatically with the [built-in tokenizer](https://github.com/spider-gazelle/tokenizer)

```crystal
def on_load
  transport.tokenizer = Tokenizer.new("\r\n")
end
```

Here are the ways to use streaming IO methods:

1. Send and receive

```crystal
def perform_action
  # You call send with some data.
  # you can also optionally pass some queue options to the function
  send("message data", priority: 30, name: "generic-message")
end

# A common received function for handling responses
def received(data, task)
  # data is always `Bytes`
  # task is always `PlaceOS::Driver::Task?` (i.e. could be nil if no active task)

  # convert data into the appropriate format
  data = String.new(data)

  # decide if the request was a success or not
  # you can pass any value that is JSON serialisable to success
  # (if it can't be serialised then nil is sent)
  task.try &.success(data)
end
```

1. Send and callback

```crystal
def perform_action
  request = "build request"

  send(request, priority: 30, name: "generic-message") do |data, task|
    data = String.new(data)

    # process response here (might need to know the request context)

    task.try &.success(data)
  end
end
```

1. Send immediately (no queuing)

```crystal
def perform_action_now!
  transport.send("no queue")
end
```

You can also add a pre-processor to data coming in. This can be useful if you want to strip away a protocol layer. For example, if you are using Telnet and want to remove the telnet signals leaving the raw data for tokenizing

```crystal
def on_load
  transport.pre_processor do |bytes|
    # you must return some byte data or nil if no processing is required
    # tokenisation occurs on the data returned here
    bytes[1..-2]
  end
end
def received(data, task)
  # data coming in here is both pre_processed and tokenised
end
```

#### HTTP Client

All drivers have built-in methods for performing HTTP requests.

* For streaming IO devices this defaults to `http://device.ip.address` (`https` if the transport is using TLS / SSH)
* All devices can provide a custom HTTP base URI

There are methods for all the typical HTTP verbs: get, post, put, patch, delete

```crystal
def perform_action
  basic_auth = "Basic #{Base64.strict_encode("#{@username}:#{@password}")}"

  response = post("/v1/message/path", body: {
    messages: numbers,
  }.to_json, headers: {
    "Authorization" => basic_auth,
    "Content-Type"  => "application/json",
    "Accept"        => "application/json",
  }, params: {
    "key" => "value"
  })

  raise "request failed with #{response.status_code}" unless (200...300).include?(data.status_code)
end
```

#### Special SSH methods

SSH connections will attempt to open a shell to the remote device. Sometimes you may be able to execute operations independently.

```crystal
def perform_action
  # if the application launched supports input you can use the bidirectional IO
  # to communicate with the app
  io = exec("command")
end
```

#### Logic drivers

Logic drivers belong to a System and cannot be shared, which makes them different from other transports. All other drivers can appear in any number of systems.

You can access remote modules in the system via the `system` helper

```crystal
# Get a system proxy
sys = system
sys.name #=> "Name of system"
sys.email #=> "resource@email.address"
sys.capacity #=> 12
sys.bookable #=> true
sys.id #=> "sys-tem~id"
sys.modules #=> ["Array", "Of", "Unique", "Module", "Names", "In", "System"]
sys.count("Module") #=> 3
sys.implementing(PlaceOS::Driver::Interface::Powerable) #=> ["Camera", "Display"]

# Look at status on a remote module
system[:Display][:power] #=> true (JSON::Any)
system[:Display].status(Bool, :power) #=> true (Bool)
system[:Display].status?(Bool, :power) #=> true (Bool | Nil)

# Access a different module index
system[:Display_2][:power]
system.get(:Display, 2)[:power]

# Access all modules of a type
system.all(:Display)

# Check if a module exists
system.exists?(:Display) #=> true
system.exists?(:Display_2) #=> false
```

You can bind to state in remote modules

```crystal
bind Display_1, :power, :power_changed

private def power_changed(subscription, new_value)
  logger.debug new_value
end

# you can also bind to internal state (available in all drivers)
bind :power, :power_changed
```

It's also possible to create shortcuts to other modules. This is powerful as these shortcuts are exposed as metadata. It allows Backoffice to perform system verification.

For example, consider the following video conference system:

```crystal
# It requires at least one camera that can move and be turned on and off
accessor camera : Array(Camera), implementing: [Powerable, Moveable]

# Optional room blinds that can be opened and closed
accessor blinds : Array(Blind)?, implementing: [Switchable]

# A single display is required with an optional screen (maybe it's a projector)
accessor main_display : Display_1, implementing: Powerable
accessor screen : Screen?
```

Cross system communication is possible if you know the ID of the remote system.

```crystal
# once you have reference to the remote system you can perform any
# actions that you might perform on the local system
sys = system("sys-12345")

sys.name #=> "Name of remote system"
sys[:Display_2][:power] #=> true
```

### Subscriptions

You can dynamically bind to state of interest in remote modules

```crystal
# subscription is returned and provided with every status update in the callback
subscription = system.subscribe(:Display_1, :power) do |subscription, new_value|
  # values are always raw JSON strings
  JSON.parse(new_value)
end

# Local subscriptions
subscription = subscribe(:state) do |subscription, new_value|
  # values are always raw JSON strings
  JSON.parse(new_value)
end

# Clearing all subscriptions
subscriptions.clear
```

Like subscriptions, channels can be setup for broadcasting any data that might not need be exposed as state.

```crystal
subscription = monitor(:channel_name) do |subscription, new_value|
  # values are always raw JSON strings
  JSON.parse(new_value)
end

# Publish something on the channel to all listeners
publish(:channel_name, "some event")
```

### Scheduler

There is a [built-in scheduler](http://github.com/spider-gazelle/tasker)

```crystal
def connected
  schedule.every(40.seconds) { poll_device }
  schedule.in(200.milliseconds) { send_hello }
end

def disconnected
  schedule.clear
end
```

### Settings

Settings are stored as JSON and then extracted as required, serializing to the specified type. There are two types:

* Required settings - raise an error if the setting is unavailable
* Optional settings - return `nil` if the setting is unavailable

{% hint style="info" %}
All settings will raise an error if they exist but fail to serialize (due to incorrect formatting etc.)
{% endhint %}

```crystal
# Required settings
def on_update
  @display_id = setting(Int32, :display_id)

  # Can extract deeply nested values
  # i.e. {input: {list: ["HDMI", "VGA"] }}
  @primary_input = setting(InputEnum, :input, :list, 0)
end

# Optional settings (you can optionally provide a default)
def on_update
  @display_id = setting?(Int32, :display_id) || 1
  @primary_input = setting?(InputEnum, :input, :list, 0) || InputEnum::HDMI
end
```

You can update the local settings of a module, persisting them to the database. Settings must be JSON serializable

```crystal
define_setting(:my_setting_name, "some JSON serialisable data")
```

### Logger

There is a [logger available](https://crystal-lang.org/api/master/Log.html)

* `warn` and above are written to disk
* `debug` and `info` are only available when there is an open debugging session

```crystal
logger.warn { "error unknown response" }
logger.debug { "function called with #{value}" }
```

The logging format has been pre-configured so all logging from PlaceOS is uniform and parsed as-is

### Metadata

Many components use metadata to simplify configuration.

* `generic_name` => the name that a system should use to access the module
* `descriptive_name` => the manufacturers name for the device
* `description` => notes or any other descriptive information you wish to add
* `tcp_port` => TCP port the TCP transport should connect to
* `udp_port` => UDP port the UDP transport should connect to
* `uri_base` => The HTTP base for any HTTP requests
* `default_settings` => Default or example settings that for configuring a module

```crystal
class MyDevice < PlaceOS::Driver
  generic_name :Driver
  descriptive_name "Driver model Test"
  description "This is the driver used for testing"
  tcp_port 22
  default_settings({
    name:     "Room 123",
    username: "steve",
    password: "$encrypt",
    complex:  {
      crazy_deep: 1223,
    },
  })

  # ...

end
```

### Security

By default all public functions are exposed for execution. You can limit who is able to execute sensitive functions.

```crystal
@[Security(Level::Administrator)]
def perform_task(name : String | Int32)
  queue &.success("hello #{name}")
end
```

Use the `Security` annotation to define the access level of the function. The options are:

* Administrator `Level::Administrator`
* Support `Level::Support`

When a user initiates a function call, within a driver, you can access that users id via the `invoked_by_user_id` function, which returns a `String` if a user initiated the call.

### Interfaces

Drivers can expose any methods that make sense for the device, service or logic they encapsulate. Across these there are often core sets of similar functionality. Interfaces provide a standard way of implementing and interacting with this.

Though optional, they're recommended as they make drivers more modular and less complex.

A full list of interfaces is [available in the driver framework](https://github.com/PlaceOS/driver/tree/master/src/placeos-driver/interface). This will expand over time to cover common, repeated patterns as they emerge.

#### Implementing an Interface

Each interface is a module containing abstract methods, types and functionality built from these.

First include the module within the driver body.

```crystal
include Interface::Powerable
```

You will then need to provide implementations of the abstract methods. The compiler will guide you in this.

Some interfaces will also provide default implementation for other methods. These may be overridden if the device or service provides a more efficient way to do the same thing. To keep compatibility, overridden methods must maintain feature and functional parity with the original.

#### Using an Interface

You can use the `system.implementing` method from any logic module. It returns a list of all drivers in the system which implement the Interface.

The `accessor` macro provides a way to declare a dependency on a sibling driver for a specific function.

For more information on these and for usage examples, see [logic drivers](./#logic-drivers).

### Handling errors

Where multiple functions are likely to raise similar errors, the errors can be handled generically using the `rescue_from` helper.

```crystal
class MyDevice < PlaceOS::Driver
  rescue_from JSON::ParseException do |error|
    logger.warn(exception: error) { "error parsing JSON payload" }
    {} of String => JSON::Any
  end

  # any external call to this function will result in the empty hash above
  # being returned to the caller. Internally in the driver the error will
  # be raised as normal.
  def no_error_externally
    JSON.parse %({invalid: 'json')
  end
end
```

Alternatively this can be handled via an explicit function. Useful if it's desirable to use the same code in the received function.

```crystal
class MyDevice < PlaceOS::Driver
  rescue_from JSON::ParseException, :handle_parse_error

  protected def handle_parse_error(error)
    logger.warn(exception: error) { "error parsing JSON payload" }
    {} of String => JSON::Any
  end
  
  # The above might be used as follows:
  
  def no_error_externally
    # externally returns {}
    JSON.parse %({invalid: 'json')
  end
  
  # Keep error parsing DRY
  def received(data, task)
    result = JSON.parse(String.new data)
    task.try &.success(result)
  rescue error : JSON::ParseException
    result = handle_parse_error(error)
    task.try &.success(result)
  end
end
```
