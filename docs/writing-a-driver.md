# How to write a driver

There are three kind of drivers

* Streaming IO (TCP, SSH, UDP, Multicast ect)
* HTTP Client
* Logic

From a driver structure standpoint there is no difference between these types.

* The same driver can be used over a TCP, UDP or SSH transport.
* All drivers support HTTP methods if a URI endpoint is defined.
* If a driver is associated with a System then it has access to logic helpers

However typically a driver will only implement one of these interfaces.


## Concepts

Backing a driver is few different pieces that make it function.

* Queue
* Transport
* Subscriptions
* Scheduler
* Settings
* Logger
* Metadata
* Security


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

In most cases you won't need to use the queue explicitly however it is good to understand that it is there and how it functions.


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
  # you can also optionally pass some queue options to the function
  send("message data", priority: 30, name: "generic-message")
end

# A common received function for handling responses
def received(data, task)
  # data is always `Bytes`
  # task is always `EngineDriver::Task?` (i.e. could be nil if no active task)

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


#### HTTP Client

All drivers have built in methods for performing HTTP requests.

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

The main difference between logic drivers and other transports is that a logic module is directly associated with a System and cannot be shared. (all other drivers can appear in multiple systems)

* You can access remote modules in the system via the `system` helper

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
sys.implementing(EngineDriver::Interface::Powerable) #=> ["Camera", "Display"]

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

you can bind to state in remote modules

```crystal

bind Display_1, :power, :power_changed

private def power_changed(subscription, new_value)
  logger.debug new_value
end


# you can also bind to internal state (available in all drivers)
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

Similarly to subscriptions, there are channels that can be setup for broadcasting
arbitrary data that might not need be exposed as state.

```crystal

subscription = monitor(:channel_name) do |subscription, new_value|
  # values are always raw JSON strings
  JSON.parse(new_value)
end

# Publish something on the channel to all listeners
publish(:channel_name, "some event")

```


### Scheduler

There is a built in scheduler: https://github.com/spider-gazelle/tasker

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


### Logger

There is a logger available: https://crystal-lang.org/api/latest/Logger.html

* Warning and above are written to disk.
* debug and info are only available when there is an open debugging session.

```crystal

logger.warn "error unknown response"

# You should typically use the block form for debug and info messages
# this only performs string interpolations if a debugging session is attached
logger.debug { "function called with #{value}" }

```

The logging format has been pre-configured so all logging from Engine is uniform and simple to parse


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

class MyDevice < EngineDriver
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

By default all public functions are exposed for execution.
However you can limit who is able to execute sensitive functions.

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
