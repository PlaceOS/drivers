module Place; end

class Place::SpecHelper < PlaceOS::Driver
  def implemented_in_driver
    "woot!"
  end
end
