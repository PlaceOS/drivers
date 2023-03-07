require "placeos-driver/spec"

class DigitalIO < DriverSpecs::MockDriver
  def ir(index : Int32, command : String)
    nil
  end
end

DriverSpecs.mock_driver "GlobalCache::IRTV" do
  system({
    DigitalIO: {DigitalIO},
  })

  # This results in an error
  # Expected: "abc_news"
  #    got: #<DriverSpecs::Responder:0x7fa6d20796e0 @channel=#<Channel(PlaceOS::Driver::Protocol::Request):0x7fa6d20c0880>> (Spec::AssertionFailed)
  # from /usr/share/crystal/src/spec/methods.cr:82:5 in 'fail'
  # from /usr/share/crystal/src/spec/expectations.cr:454:9 in 'should'
  #
  # [E]  message="executing {"__exec__":"channel","channel":["abc_news"]} on GlobalCache::IRTV (spec_runner)" user_id=internal request_id=spec_runner
  # undefined method 'ir' for DigtialIO_1 (driver index unavailable) (Exception)
  #   from repositories/local/lib/placeos-driver/src/placeos-driver/proxy/driver.cr:128:7 in '__exec_request__'
  #   from repositories/local/lib/placeos-driver/src/placeos-driver/proxy/driver.cr:12:5 in '??'
  #   from repositories/local/drivers/global_cache/ir_tv.cr:156:7 in 'channel'
  exec(:channel, "abc_news").should eq("abc_news")
  status[:current_channel].should eq("abc_news")

  # This succeeds
  status[:channel_details].should eq(
    [
      {
        "name"        => "ABC News",
        "icon"        => "https://url-to-svg-or-png",
        "id"          => "abc_news",
        "ir_commands" => ["DIGIT 0", "DIGIT 2", "DIGIT 4"],
      },
      {
        "name"        => "Channel Down",
        "icon"        => "https://url-to-svg-or-png",
        "id"          => "down",
        "ir_commands" => ["CHANNEL_DOWN"],
      },
      {
        "name"        => "Channel Up",
        "icon"        => "https://url-to-svg-or-png",
        "id"          => "up",
        "ir_commands" => ["CHANNEL_UP"],
      },
    ]
  )
end
