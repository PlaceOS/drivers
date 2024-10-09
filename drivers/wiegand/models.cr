module Wiegand
  # Ported from: https://github.com/acaprojects/ruby-engine-drivers/blob/beta/lib/hid/algorithms.rb
  class Base
    property wiegand : UInt64
    property facility : UInt32
    property card_number : UInt32

    def initialize(wiegand : UInt64, facility : UInt32, card_number : UInt32)
      @wiegand = wiegand
      @facility = facility
      @card_number = card_number
    end

    def self.count_1s(int : UInt32 | UInt64)
      int.to_s(2).gsub("0", "").size
    end
  end

  class Wiegand26 < Base
    FAC_PAR_MASK  = 0b11111111100000000000000000
    FACILITY_MASK = 0b01111111100000000000000000
    CARD_MASK     = 0b00000000011111111111111110
    CARD_PAR_MASK = 0b00000000011111111111111111

    # Convert wiegand 26 card data to components
    #
    # Hex card data: 0x21a6616
    # Card Number: 13067
    # Card Facility Code: 13
    def from_wiegand(wiegand : UInt64)
      card_number = (wiegand & CARD_MASK) >> 1
      card_1s = count_1s(wiegand & CARD_PAR_MASK)

      facility = (wiegand & FACILITY_MASK) >> 17
      facility_1s = count_1s(wiegand & FAC_PAR_MASK)

      parity_passed = card_1s.odd? && facility_1s.even?
      raise "parity check error" unless parity_passed

      Wiegand26.new(wiegand.to_u64, facility, card_number)
    end

    # Convert components to wiegand 26 card data
    def self.from_components(facility : UInt32, card_number : UInt32)
      wiegand = 0

      wiegand += card_number << 1
      # Build the card parity bit (should be an odd number of ones)
      wiegand += (FAC_PAR_MASK ^ FACILITY_MASK) if count_1s(card_number).odd?

      wiegand += facility << 17
      # Build facility parity bit (should be an even number of ones)
      wiegand += 1 if count_1s(facility).even?

      Wiegand26.new(wiegand.to_u64, facility, card_number)
    end
  end

  class Wiegand35 < Base
    PAR_EVEN_MASK = 0b01101101101101101101101101101101100
    PAR_ODD_MASK  = 0b00110110110110110110110110110110110
    CARD_MASK     = 0b00000000000001111111111111111111100
    FACILITY_MASK = 0b01111111111110000000000000000000000

    # Outputs the HEX code of what is written to the swipe card
    #
    # Hex card data: 0x06F20107F
    # Card Number: 2540
    # Card Facility Code: 4033
    def from_components(facility : UInt32, card_number : UInt32)
      wiegand = (facility << 22) + (card_number << 2)
      even_count = count_1s(wiegand & PAR_EVEN_MASK)
      odd_count = count_1s(wiegand & PAR_ODD_MASK)

      # Even Parity
      wiegand += (1 << 34) if even_count.odd?

      # Odd Parity
      wiegand += 2 if odd_count.even?
      wiegand = wiegand.to_s(2).rjust(35, '0').reverse.to_i(2)

      Wiegand35.new(wiegand.to_u64, facility, card_number)
    end

    # Convert wiegand 35 card data to components
    #
    # 1 + 12 + 20 + 2
    # 1 + facility + card num + 2
    def self.from_wiegand(wiegand)
      str = wiegand.to_s(2).rjust(35, '0').reverse
      data = str.to_i(2)
      even_count = count_1s(data & PAR_EVEN_MASK) + (str[0] == '1' ? 1 : 0)
      odd_count = count_1s(data & PAR_ODD_MASK)

      parity_passed = odd_count.odd? && even_count.even?
      raise "parity check error" unless parity_passed

      facility = (data & FACILITY_MASK) >> 22
      card_number = (data & CARD_MASK) >> 2
      Wiegand35.new(wiegand.to_u64, facility, card_number)
    end
  end
end
