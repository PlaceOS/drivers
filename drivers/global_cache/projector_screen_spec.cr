require "placeos-driver/spec"

# To do: Actually write the spec

class Screen < DriverSpecs::MockDriver
end

DriverSpecs.mock_driver "GlobalCache::ProjectorScreen" do
  system({
    Screen: {Screen},
  })
end
