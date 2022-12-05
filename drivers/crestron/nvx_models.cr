require "json"

module Crestron
  # Interface for enumerating devices
  module Transmitter
  end

  module Receiver
  end

  enum AspectRatio
    MaintainAspectRatio
    StretchToFit
  end

  enum SourceType
    Audio
    Video
  end
end
