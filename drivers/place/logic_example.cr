module Place; end

class Place::LogicExample < PlaceOS::Driver
  accessor main_lcd : Display_1, implementing: Powerable

  def power_state?
    main_lcd[:power]
  end

  def power(state : Bool)
    main_lcd.power(state)
  end
end
