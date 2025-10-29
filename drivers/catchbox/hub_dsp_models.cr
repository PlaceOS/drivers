require "json"

module Catchbox
  struct ApiRequest
    include JSON::Serializable

    property rx : RxCommand?

    def initialize(@rx : RxCommand? = nil)
    end
  end

  struct ApiResponse
    include JSON::Serializable

    property rx : RxResponse?
    property error : Int32 = 0

    def initialize(@rx : RxResponse? = nil, @error : Int32 = 0)
    end
  end

  struct RxCommand
    include JSON::Serializable

    property network : NetworkCommand?
    property device : DeviceCommand?
    property audio : AudioCommand?

    def initialize(@network : NetworkCommand? = nil, @device : DeviceCommand? = nil, @audio : AudioCommand? = nil)
    end
  end

  struct RxResponse
    include JSON::Serializable

    property network : NetworkResponse?
    property device : DeviceResponse?
    property audio : AudioResponse?

    def initialize(@network : NetworkResponse? = nil, @device : DeviceResponse? = nil, @audio : AudioResponse? = nil)
    end
  end

  struct NetworkCommand
    include JSON::Serializable

    property mac : String?
    property ip_mode : String?
    property ip : String?
    property subnet : String?
    property gateway : String?
    property reboot : Bool?

    def initialize(@mac : String? = nil, @ip_mode : String? = nil, @ip : String? = nil, @subnet : String? = nil, @gateway : String? = nil, @reboot : Bool? = nil)
    end
  end

  struct NetworkResponse
    include JSON::Serializable

    property mac : String?
    property ip_mode : String?
    property ip : String?
    property subnet : String?
    property gateway : String?

    def initialize(@mac : String? = nil, @ip_mode : String? = nil, @ip : String? = nil, @subnet : String? = nil, @gateway : String? = nil)
    end
  end

  struct DeviceCommand
    include JSON::Serializable

    property name : String?

    def initialize(@name : String? = nil)
    end
  end

  struct DeviceResponse
    include JSON::Serializable

    property name : String?
    property firmware : String?
    property hardware : String?
    property serial : String?

    def initialize(@name : String? = nil, @firmware : String? = nil, @hardware : String? = nil, @serial : String? = nil)
    end
  end

  struct AudioCommand
    include JSON::Serializable

    property input : AudioInputCommand?

    def initialize(@input : AudioInputCommand? = nil)
    end
  end

  struct AudioResponse
    include JSON::Serializable

    property input : AudioInputResponse?

    def initialize(@input : AudioInputResponse? = nil)
    end
  end

  struct AudioInputCommand
    include JSON::Serializable

    property mic1 : MicCommand?
    property mic2 : MicCommand?
    property mic3 : MicCommand?

    def initialize(@mic1 : MicCommand? = nil, @mic2 : MicCommand? = nil, @mic3 : MicCommand? = nil)
    end
  end

  struct AudioInputResponse
    include JSON::Serializable

    property mic1 : MicResponse?
    property mic2 : MicResponse?
    property mic3 : MicResponse?

    def initialize(@mic1 : MicResponse? = nil, @mic2 : MicResponse? = nil, @mic3 : MicResponse? = nil)
    end
  end

  struct MicCommand
    include JSON::Serializable

    property mute : Bool?

    def initialize(@mute : Bool? = nil)
    end
  end

  struct MicResponse
    include JSON::Serializable

    property mute : Bool?
    property battery : Int32?
    property signal : Int32?
    property connected : Bool?

    def initialize(@mute : Bool? = nil, @battery : Int32? = nil, @signal : Int32? = nil, @connected : Bool? = nil)
    end
  end
end