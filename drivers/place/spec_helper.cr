module Place; end

class Place::SpecHelper < PlaceOS::Driver
  # This method will be exposed on the module
  def implemented_in_driver
    "woot!"
  end
end
