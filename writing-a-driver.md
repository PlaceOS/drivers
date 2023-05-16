# How to write a PlaceOS Driver

There are three kinds of PlaceOS Drivers...

- [Streaming IO (TCP, SSH, UDP, Multicast, etc.)](#streaming-io)
- [HTTP Client](#http-client)
- [Logic](#logic-drivers)

From a Driver structure standpoint, there is no difference between these types.

- The same Driver can be used over a TCP, UDP or SSH transport.
- All Drivers support HTTP methods if a URI endpoint is defined.
- If a Driver is associated with a System then it has access to logic helpers

However, typically a Driver will only implement one of these interfaces.


## Concepts

There are a few components of the PlaceOS Driver system...

- [Lifecycle](#lifecycle)
- [Queue](#queue)
- [Transport](#transport)
- [Subscriptions](#subscriptions)
- [Scheduler](#scheduler)
- [Settings](#settings)
- [Logger](#logger)
- [Metadata](#metadata)
- [Security](#security)
- [Interfaces](#interfaces)

### Lifecycle

All PlaceOS Drivers have a lifecycle that is managed by the system.

There are 5 lifecycle events:

* `#on_load` - Called when a driver is added to a system.
* `#on_update` - Called when settings are updated.
* `#on_unload` - Called when a driver is removed from a system.
* `#connected` - Called when a driver becomes active.
* `#disconnected` - Called when a driver becomes inactive.

For more information on these and other driver methods, see [PlaceOS Driver](https://github.com/PlaceOS/driver).

### Queue

The queue is a list of potentially asynchronous tasks that should be performed in a sequence.

* Each task has a priority (defaults to `50`) - higher priority tasks run first
* Tasks can be named. If a new task is added with the same name it replaces the existing task.
* Tasks have a timeout (defaults to `5.seconds`)
* Tasks can be retried (defaults to `3` before failing)

Tasks have a callback that is used to run the task

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

In most cases, you won't need to use the queue explicitly however it is good to understand that it is there and how it functions.


### Transport

The transport loaded is defined by settings in the database.

#### Streaming IO

You should always tokenise your streams.
This can be handled automatically by the [built in tokeniser](https://github.com/spider-gazelle/tokenizer)

```crystal

def on_load
  transport.tokenizer = Tokenizer.new("\r\n")
end

```

There are a few ways to use streaming IO methods:

1. send and receive

```crystal

def perform_action
  # You call send with some data.
  # You can also optionally pass some queue options to the function
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

2. send and callback

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

3. send immediately (no queuing)

```crystal

def perform_action_now!
  transport.send("no queue")
end

```

You can also add a pre-processor to data coming in. This can be useful
if you want to strip away a protocol layer i.e. you are communicating
over Telnet and want to remove the telnet signals leaving the raw
comms for tokenising

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

All PlaceOS Drivers have built-in methods for performing HTTP requests.

* For streaming IO devices this defaults to `http://device.ip.address` or `https` if the transport is using TLS / SSH.
* All devices can provide a custom HTTP base URI.

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

SSH connections will attempt to open a shell to the remote device however sometimes you may be able to execute operations independently.

```crystal

def perform_action
  # if the application launched supports input you can use the bidirectional IO
  # to communicate with the app
  io = exec("command")
end

```


#### Logic drivers

The main difference between Logic Drivers and other transports is that a logic module is directly associated with a System and cannot be shared. (all other Drivers can appear in multiple systems)

- You can access remote modules in the system via the `system` helper

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
system[:Display][:power] #=> true

# Access a different module index
system[:Display_2][:power]
system.get(:Display, 2)[:power]

# Access all modules of a type
system.all(:Display)

# Check if a module exists
system.exists?(:Display) #=> true
system.exists?(:Display_2) #=> false

```

- You can bind to state in remote modules

```crystal

bind Display_1, :power, :power_changed

private def power_changed(subscription, new_value)
  logger.debug new_value
end


# You can also bind to Driver's internal state (available in all Drivers)
bind :power, :power_changed

```

It's also possible to create shortcuts to other modules.
This is powerful as these shortcuts are exposed as metadata - allowing backoffice to perform system verification.

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

Cross-system communication is possible if you know the ID of the remote system.

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

# Subscription is returned and provided with every status update in the callback
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

Similarly to subscriptions,  channels can be set up for broadcasting
arbitrary data that might not need to be exposed as Driver state.

```crystal

subscription = monitor(:channel_name) do |subscription, new_value|
  # values are always raw JSON strings
  JSON.parse(new_value)
end

# Publish something on the channel to all listeners
publish(:channel_name, "some event")

```


### Scheduler

There is a built-in scheduler: https://github.com/spider-gazelle/tasker

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

Settings are stored as JSON and then extracted as required, serialising to the specified type
There are two types:

* Required settings - raise an error if the setting is unavailable
* Optional settings - return `nil` if the setting is unavailable

NOTE:: All settings will raise an error if they exist but fail to serialise (as they are not formatted correctly etc)

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

You can update the local settings of a module, persisting them to the database. Settings must be JSON serialisable

```crystal
define_setting(:my_setting_name, "some JSON serialisable data")
```


### Logger

There is a logger available: https://crystal-lang.org/api/latest/Logger.html

* Warning and above are written to disk.
* debug and info are only available when there is an open debugging session.

```crystal

logger.warn { "error unknown response" }
logger.debug { "function called with #{value}" }

```

The logging format has been pre-configured so all logging from PlaceOS is uniform and simple to parse


### Metadata

Metadata is used by various components to simplify configuration.

* `generic_name` => the name that should be used in a system to access the module
* `descriptive_name` => the manufacturers name for the device
* `description` => notes or any other descriptive information you wish to add
* `tcp_port` => TCP port the TCP transport should connect to
* `udp_port` => UDP port the UDP transport should connect to
* `uri_base` => The HTTP base for any HTTP requests
* `default_settings` => Defaults or example settings that should be used to configure a module


```crystal

class MyDevice < PlaceOS::Driver
  generic_name :Driver
  descriptive_name "Driver model Test"
  description "This is the Driver used for testing"
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

By default, all public functions are exposed for execution.
However, you can limit who can execute sensitive functions.

```crystal

@[Security(Level::Administrator)]
def perform_task(name : String | Int32)
  queue &.success("hello #{name}")
end

```

Use the `Security` annotation to define the access level of the function.
The options are:

* Administrator `Level::Administrator`
* Support `Level::Support`

### Interfaces

PlaceOS Drivers can expose any methods that make sense for the device, service or logic they encapsulate.
Across these, there are often core sets of similar functionality.
Interfaces provide a standard way of implementing and interacting with this.

Their usage is optional but highly encouraged as it both improves modularity and reduces complexity in Driver implementations.

A full list of interfaces is [available in the PlaceOS Driver framework](https://github.com/PlaceOS/driver/tree/master/src/placeos-driver/interface).
This will expand over time to cover common, repeated patterns as they emerge.

#### Implementing an Interface

Each interface is a module containing abstract methods, types and functionality built from these.

First, include the module within the Driver body.
```crystal
include Interface::Powerable
```
You will then need to provide implementations of the abstract methods.
The compiler will guide you in this.

Some interfaces will also provide a default implementation for other methods.
These may be overridden if the device or service provides a more efficient way to directly execute the desired behaviour.
To keep compatibility, overridden methods must maintain feature and functional parity with the original implementation.

#### Using an Interface

Drivers that provide an Interface can be discovered using the `system.implementing` method from any logic module.
This will return a list of all Drivers in the system which implement the Interface.

Similarly, the `accessor` macro provides a way to declare a dependency on a sibling Driver that provides specific functionality.

For more information on these and usage examples, see [Logic Drivers](#logic-drivers).

