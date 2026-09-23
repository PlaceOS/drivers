require "placeos-driver/spec"
require "http/server"

# :nodoc:
# the driver talks to each core node over that nodes internal API, so we stand up
# fake core pods on local ports and point the driver at them
CORE_0_PORT = 8341
CORE_1_PORT = 8342
CORE_2_PORT = 8343

CORE_0_ID = "01M073D9GRBDTX8Q1XH5ZYQN9W"
CORE_1_ID = "01M073D9GRBDTX8Q1XH5ZYQN9X"
CORE_2_ID = "01M073D9GRBDTX8Q1XH5ZYQN9Y"

DISPLAY  = "drivers_place_demo_display_4894a36_arm64"
BOOKINGS = "drivers_place_bookings_1a2b3c4_arm64"
ROUTER   = "drivers_place_router_9f8e7d6_arm64"
KIOSK    = "drivers_place_kiosk_2c3d4e5_arm64"

EDGE_A = "edge-abc"
EDGE_B = "edge-xyz"

# maps a driver to the memory it's using, nil for a driver core has no status for
alias Drivers = Hash(String, Int64?)
alias Metadata = NamedTuple(running: Bool, memory_usage: Int64)

# :nodoc:
def metadata(memory : Int64?) : Metadata?
  memory.nil? ? nil : {running: memory > 0, memory_usage: memory}
end

# :nodoc:
def modules(drivers : Drivers)
  drivers.keys.to_h { |driver| {driver, ["mod-#{driver}"]} }
end

# a driver binary that wasn't named by the build service
LEGACY = "legacy_driver"

# :nodoc:
alias DriverState = NamedTuple(name: String, hostname: String, commit: String, running: Int32, timestamp: Int64)

# :nodoc:
def system_load(hostname : String)
  {
    hostname:     hostname,
    cpu_count:    4,
    core_cpu:     0.5,
    total_cpu:    1.5,
    memory_total: 8_000_000_i64,
    memory_usage: 4_000_000_i64,
    core_memory:  100_000_i64,
  }
end

# :nodoc:
# a core node reports its own driver processes plus those on each edge attached
# to it, keyed by edge id
def serve_core(port : Int32, hostname : String, drivers : Drivers, edges : Hash(String, Drivers) = {} of String => Drivers)
  server = HTTP::Server.new do |context|
    context.response.content_type = "application/json"

    case context.request.path
    when "/api/core/v1/status/load"
      context.response.print({local: system_load(hostname), edge: {} of String => String}.to_json)
    when "/api/core/v1/status/loaded"
      context.response.print({
        local: modules(drivers),
        edge:  edges.transform_values { |edge| modules(edge) },
      }.to_json)
    when "/api/core/v1/status/driver"
      driver = context.request.query_params["path"]
      edge_status = {} of String => Metadata?
      edges.each { |edge_id, edge| edge_status[edge_id] = metadata(edge[driver]) if edge.has_key? driver }
      context.response.print({local: metadata(drivers[driver]?), edge: edge_status}.to_json)
    else
      context.response.status_code = 404
    end
  end

  # bind before spawning so the port is accepting connections by the time the
  # driver makes a request
  server.bind_tcp "127.0.0.1", port
  spawn { server.listen }
  server
end

# :nodoc:
def serve_broken_core(port : Int32)
  server = HTTP::Server.new do |context|
    context.response.status_code = 500
    context.response.print("core is not well")
  end
  server.bind_tcp "127.0.0.1", port
  spawn { server.listen }
  server
end

# EDGE_A is attached to both core nodes, so it gets reported twice and has to be
# deduplicated. it reports the same memory either way so the result is unambiguous
serve_core(CORE_0_PORT, "core-0",
  Drivers{DISPLAY => 12_345_i64, BOOKINGS => 0_i64},
  {EDGE_A => Drivers{KIOSK => 0_i64}})
serve_core(CORE_1_PORT, "core-1",
  Drivers{ROUTER => nil, LEGACY => 6_789_i64},
  {EDGE_A => Drivers{DISPLAY => 4_000_i64, KIOSK => 0_i64}, EDGE_B => Drivers{KIOSK => 9_000_i64}})
serve_broken_core(CORE_2_PORT)

DriverSpecs.mock_driver "Place::DriverHealth" do
  # 0 disables the schedule so the checks below are the only ones that run
  settings({
    check_every_minutes: 0,
    core_nodes:          {
      CORE_0_ID => "http://127.0.0.1:#{CORE_0_PORT}",
      CORE_1_ID => "http://127.0.0.1:#{CORE_1_PORT}",
    },
  })

  it "reports the configured cluster nodes" do
    nodes = Hash(String, String).from_json exec(:cluster_nodes).get.not_nil!.to_json
    nodes.should eq({
      CORE_0_ID => "http://127.0.0.1:#{CORE_0_PORT}",
      CORE_1_ID => "http://127.0.0.1:#{CORE_1_PORT}",
    })
  end

  it "checks the memory use of every driver process in the cluster" do
    before = Time.utc.to_unix
    results = Array(DriverState)
      .from_json exec(:check_drivers).get.not_nil!.to_json

    results.size.should eq 7

    # a driver using memory is running, the commit and architecture are split
    # out of the executable name
    results[1][:name].should eq "drivers_place_demo_display"
    results[1][:hostname].should eq "core-0"
    results[1][:commit].should eq "4894a36"
    results[1][:running].should eq 1

    # a driver using no memory is not
    results[0][:name].should eq "drivers_place_bookings"
    results[0][:hostname].should eq "core-0"
    results[0][:commit].should eq "1a2b3c4"
    results[0][:running].should eq 0

    # neither is one core has no status for
    results[2][:name].should eq "drivers_place_router"
    results[2][:hostname].should eq "core-1"
    results[2][:commit].should eq "9f8e7d6"
    results[2][:running].should eq 0

    # an executable the build service didn't name is reported as is
    results[3][:name].should eq LEGACY
    results[3][:hostname].should eq "core-1"
    results[3][:commit].should eq ""
    results[3][:running].should eq 1

    # a process on an edge is reported against the edge, not the node reporting
    # it. EDGE_A is attached to both core nodes yet appears once, and the same
    # driver on two hosts keeps the same name
    results[4..].map { |result| {result[:name], result[:hostname], result[:running]} }.should eq [
      {"drivers_place_demo_display", EDGE_A, 1}, # on an edge, using memory
      {"drivers_place_kiosk", EDGE_A, 0},        # on an edge, using no memory
      {"drivers_place_kiosk", EDGE_B, 1},        # a second edge of the same node
    ]

    # each result is stamped with when it was checked
    results.each do |result|
      result[:timestamp].should be >= before
      result[:timestamp].should be <= Time.utc.to_unix
    end

    status[:driver_count].should eq 7
    status[:running_count].should eq 4

    # not running processes are identified by host as well as driver
    Array(String).from_json(status[:not_running].to_json).should eq [
      "core-0.drivers_place_bookings",
      "core-1.drivers_place_router",
      "#{EDGE_A}.drivers_place_kiosk",
    ]

    Array(NamedTuple(id: String, name: String)).from_json(status[:clusters].to_json).should eq [
      {id: CORE_0_ID, name: "core-0"},
      {id: CORE_1_ID, name: "core-1"},
    ]

    Array(String).from_json(status[:unreachable_clusters].to_json).should be_empty
    status[:last_checked].as_i64.should be >= before

    # the state matches what the function returned, shaped so the influx
    # exporter tags each point with the driver name and node
    drivers = status[:drivers]
    drivers["ts_hint"].should eq "complex"
    Array(String).from_json(drivers["ts_tag_keys"].to_json).should eq ["name", "hostname"]
    Array(DriverState)
      .from_json(drivers["value"].to_json).should eq results
  end

  it "flags a node it can't reach and still checks the rest" do
    settings({
      check_every_minutes: 0,
      core_nodes:          {
        CORE_0_ID => "http://127.0.0.1:#{CORE_0_PORT}",
        CORE_2_ID => "http://127.0.0.1:#{CORE_2_PORT}",
      },
    })

    results = Array(DriverState)
      .from_json exec(:check_drivers).get.not_nil!.to_json

    results.map { |result| {result[:hostname], result[:name]} }.should eq [
      {"core-0", "drivers_place_bookings"},
      {"core-0", "drivers_place_demo_display"},
      {EDGE_A, "drivers_place_kiosk"},
    ]

    Array(String).from_json(status[:unreachable_clusters].to_json).should eq [CORE_2_ID]
    Array(NamedTuple(id: String, name: String)).from_json(status[:clusters].to_json).should eq [
      {id: CORE_0_ID, name: "core-0"},
    ]
    status[:driver_count].should eq 3
    status[:running_count].should eq 1
  end
end
