require "placeos-driver/spec"

class DigitalIO < DriverSpecs::MockDriver
  @called : Int32 = 0

  def ir(index : Int32, command : String)
    @called += 1
    self[:call_count] = @called
    nil
  end
end

DriverSpecs.mock_driver "GlobalCache::IRTV" do
  system({
    DigitalIO: {DigitalIO},
  })

  exec(:channel, "abc_news").get
  status[:current_channel].should eq("abc_news")

  system(:DigitalIO_1)[:call_count].should eq 3

  status[:channel_details].should eq(
    [
      {
        "name"        => "ABC News",
        "icon"        => "https://os.place.tech/placeos.pwc.com.au/tv_icons/ABC_News_AU.svg",
        "channel"     => "abc_news",
        "ir_commands" => ["DIGIT 0", "DIGIT 2", "DIGIT 4"],
      },
      {
        "name"        => "Channel Down",
        "icon"        => "https://static.thenounproject.com/png/1129950-200.png",
        "channel"     => "down",
        "ir_commands" => ["CHANNEL DOWN"],
      },
      {
        "name"        => "Channel Up",
        "icon"        => "https://static.thenounproject.com/png/1129949-200.png",
        "channel"     => "up",
        "ir_commands" => ["CHANNEL UP"],
      },
    ]
  )
end
