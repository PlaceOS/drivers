require "json"

module Place
  struct HelpPage
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter icon : String?
    getter title : String
    getter content : String
  end

  alias Help = Hash(String, HelpPage)
end
