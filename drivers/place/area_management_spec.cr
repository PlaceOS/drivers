require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::AreaCount" do
  # Used this tool to work out coordinates: https://www.mathsisfun.com/geometry/polygons-interactive.html
  exec(:is_inside?, 4, 5, "lobby1").get.should eq(true)
  exec(:is_inside?, 4, 4, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 5, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 4, "lobby1").get.should eq(true)
  exec(:is_inside?, 5, 3, "lobby1").get.should eq(true)
  exec(:is_inside?, 3.1, 5, "lobby1").get.should eq(true)

  exec(:is_inside?, 3, 6, "lobby1").get.should eq(false)
  exec(:is_inside?, 4, 6, "lobby1").get.should eq(false)
  exec(:is_inside?, 4.6, 5.9, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.2, 5.4, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.5, 1.5, "lobby1").get.should eq(false)
  exec(:is_inside?, 5.9, 2, "lobby1").get.should eq(false)
end
