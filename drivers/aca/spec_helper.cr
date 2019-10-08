module ACA; end

class ACA::SpecHelper < ACAEngine::Driver
  def implemented_in_driver
    "woot!"
  end
end
