require "json"

# Models used by the OpenAccess system.
#
# NOTE: naming here must match that used by OpenAccess - struct names are passed
# as meaningful information within API requests.
module Lenel::Models
  # Defines a new Lenel data type.
  private macro lnl(name, *attrs)
    record Lnl_{{name}}, {{*attrs}} do
      include JSON::Serializable
      def self.name
        "Lnl_{{name}}"
      end
    end
  end

  lnl AccessGroup, id : Int32, segmentid : Int32, name : String
end
