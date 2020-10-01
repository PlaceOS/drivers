module Place; end

require "placeos-driver/interface/locatable"

class Place::LocationServices < PlaceOS::Driver
  descriptive_name "PlaceOS Location Services"
  generic_name :LocationServices
  description %(collects location data from compatible services and combines the data)

  # Runs through all the services that support the Locatable interface
  # requests location information on the identifier for all of them
  # concatenates the results and returns them as a single array
  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }
    located = [] of JSON::Any
    system.implementing(Interface::Locatable).locate_user(email, username).get.each do |locations|
      located.concat locations.as_a
    end
    located
  end
end
