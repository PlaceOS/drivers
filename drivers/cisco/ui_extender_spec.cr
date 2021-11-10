require "placeos-driver/spec"
# require "./collaboration_endpoint"

DriverSpecs.mock_driver "Cisco::UIExtender" do
  system({
    VidConf: {VidConfMock},
  })

  system({
    VidConf: {VidConfMock},
  })

  resp = exec(:set, "something", true).get
  puts resp.inspect
  sleep 1
end

# :nodoc:
class VidConfMock < DriverSpecs::MockDriver
  def on_load
    spawn(same_thread: true) {
      sleep 0.5
      self[:ready] = self[:connected] = true
    }
  end

  def xcommand(
    command : String,
    multiline_body : String? = nil,
    hash_args : Hash(String, JSON::Any::Type) = {} of String => JSON::Any::Type
  )
    puts "Running command: #{command} #{hash_args} + body #{multiline_body.try(&.size) || 0}"
  end

  def on_event(path : String, mod_id : String, channel : String)
    puts "Registering callback for #{path} to #{mod_id}/#{channel}"
  end

  def clear_event(path : String)
    puts "Clearing event subscription for #{path}"
  end
end
