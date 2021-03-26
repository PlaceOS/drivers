require "uri"
require "http"
require "json"
require "colorize"
require "option_parser"

host = "localhost"
port = 8080
repo = ""

OptionParser.parse(ARGV.dup) do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

  parser.on("-h HOST", "--host=HOST", "Specifies the server host") { |h| host = h }
  parser.on("-p PORT", "--port=PORT", "Specifies the server port") { |p| port = p.to_i }
  parser.on("-r REPO", "--repo=REPO", "Specifies the repository to report on") { |r| repo = r }
end

puts "running report against #{host}:#{port} (#{repo.blank? ? "default" : repo} repository)"

# ================
# driver discovery
# ================
print "discovering drivers... "

response = HTTP::Client.get "http://#{host}:#{port}/build"
if !response.success?
  puts "failed to obtain driver list"
  exit 1
end

drivers = Array(String).from_json(response.body)
puts "found #{drivers.size}"
# ================

# ==============
# spec discovery
# ==============
print "locating specs... "

response = HTTP::Client.get "http://#{host}:#{port}/test"
if !response.success?
  puts "failed to obtain spec list"
  exit 2
end

specs = Array(String).from_json(response.body)
puts "found #{specs.size}"
# ==============

compile_only = [] of String
failed = [] of String
timeout = [] of String

tested = 0
success = 0

skip_remaining = false
Signal::INT.trap do |signal|
  skip_remaining = true
  signal.ignore
end

drivers.each do |driver|
  break if skip_remaining

  spec = "#{driver.rchop(".cr")}_spec.cr"
  if !specs.includes? spec
    compile_only << driver
    next
  end

  tested += 1
  print "testing #{driver}... "

  params = URI::Params.new({
    "driver" => [driver],
    "spec"   => [spec],
    "force"  => ["true"],
  })
  params["repository"] = repo unless repo.blank?
  uri = URI.new(path: "/test", query: params)

  client = HTTP::Client.new(host, port)
  client.read_timeout = 6.minutes
  begin
    response = client.post(uri.to_s)
    if response.success?
      success += 1
      puts "passed".colorize.green
    else
      puts "failed".colorize.red
      failed << driver
    end
  rescue IO::TimeoutError
    puts "failed with timeout".colorize.red
    timeout << driver
  end
end

compile_only.each do |driver|
  break if skip_remaining

  print "compile #{driver}... "
  client = HTTP::Client.new(host, port)
  client.read_timeout = 6.minutes
  begin
    response = client.post("/build?driver=#{driver}")
    if response.success?
      success += 1
      puts "builds".colorize.green
    else
      puts "failed".colorize.red
      failed << driver
    end
  rescue IO::TimeoutError
    puts "failed with timeout".colorize.red
    timeout << driver
  end
end

puts "\n"
puts "failures:\n * #{failed.join("\n * ")}"

puts "\n"
puts "timeouts:\n * #{timeout.join("\n * ")}"

puts "\n"
puts "#{tested} drivers, #{failed.size} failures, #{timeout.size} timeouts, #{compile_only.size} without spec"
