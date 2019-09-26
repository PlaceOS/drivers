module Protocols; end

# == References
# There are a large number of RFCs relevant to the Telnet protocol.
# RFCs 854-861 define the base protocol.  For a complete listing
# of relevant RFCs, see
# http://www.omnifarious.org/~hopper/technical/telnet-rfc.html
# https://github.com/ruby/net-telnet/blob/master/lib/net/telnet.rb

class Protocols::Telnet
  IAC  = 255_u8 # "\377" # "\xff" # interpret as command
  DONT = 254_u8 # "\376" # "\xfe" # you are not to use option
  DO   = 253_u8 # "\375" # "\xfd" # please, you use option
  WONT = 252_u8 # "\374" # "\xfc" # I won't use option
  WILL = 251_u8 # "\373" # "\xfb" # I will use option

  SB    = 250_u8 # "\372" # "\xfa" # interpret as subnegotiation
  GA    = 249_u8 # "\371" # "\xf9" # go ahead
  EL    = 248_u8 # "\370" # "\xf8" # erase the current line
  EC    = 247_u8 # "\367" # "\xf7" # erase the current character
  AYT   = 246_u8 # "\366" # "\xf6" # are you there
  AO    = 245_u8 # "\365" # "\xf5" # abort output--but let prog finish
  IP    = 244_u8 # "\364" # "\xf4" # interrupt process--permanently
  BREAK = 243_u8 # "\363" # "\xf3" # break
  DM    = 242_u8 # "\362" # "\xf2" # data mark--for connect. cleaning
  NOP   = 241_u8 # "\361" # "\xf1" # no operation
  SE    = 240_u8 # "\360" # "\xf0" # end sub negotiation
  EOR   = 239_u8 # "\357" # "\xef" # end of record (transparent mode)
  ABORT = 238_u8 # "\356" # "\xee" # Abort process
  SUSP  = 237_u8 # "\355" # "\xed" # Suspend process
  EOF   = 236_u8 # "\354" # "\xec" # End of file
  SYNCH = 242_u8 # "\362" # "\xf2" # for telfunc calls

  OPT_BINARY         =   0_u8 # "\000" # "\x00" # Binary Transmission
  OPT_ECHO           =   1_u8 # "\001" # "\x01" # Echo
  OPT_RCP            =   2_u8 # "\002" # "\x02" # Reconnection
  OPT_SGA            =   3_u8 # "\003" # "\x03" # Suppress Go Ahead
  OPT_NAMS           =   4_u8 # "\004" # "\x04" # Approx Message Size Negotiation
  OPT_STATUS         =   5_u8 # "\005" # "\x05" # Status
  OPT_TM             =   6_u8 # "\006" # "\x06" # Timing Mark
  OPT_RCTE           =   7_u8 # "\a"   # "\x07" # Remote Controlled Trans and Echo
  OPT_NAOL           =   8_u8 # "\010" # "\x08" # Output Line Width
  OPT_NAOP           =   9_u8 # "\t"   # "\x09" # Output Page Size
  OPT_NAOCRD         =  10_u8 # "\n"   # "\x0a" # Output Carriage-Return Disposition
  OPT_NAOHTS         =  11_u8 # "\v"   # "\x0b" # Output Horizontal Tab Stops
  OPT_NAOHTD         =  12_u8 # "\f"   # "\x0c" # Output Horizontal Tab Disposition
  OPT_NAOFFD         =  13_u8 # "\r"   # "\x0d" # Output Formfeed Disposition
  OPT_NAOVTS         =  14_u8 # "\016" # "\x0e" # Output Vertical Tabstops
  OPT_NAOVTD         =  15_u8 # "\017" # "\x0f" # Output Vertical Tab Disposition
  OPT_NAOLFD         =  16_u8 # "\020" # "\x10" # Output Linefeed Disposition
  OPT_XASCII         =  17_u8 # "\021" # "\x11" # Extended ASCII
  OPT_LOGOUT         =  18_u8 # "\022" # "\x12" # Logout
  OPT_BM             =  19_u8 # "\023" # "\x13" # Byte Macro
  OPT_DET            =  20_u8 # "\024" # "\x14" # Data Entry Terminal
  OPT_SUPDUP         =  21_u8 # "\025" # "\x15" # SUPDUP
  OPT_SUPDUPOUTPUT   =  22_u8 # "\026" # "\x16" # SUPDUP Output
  OPT_SNDLOC         =  23_u8 # "\027" # "\x17" # Send Location
  OPT_TTYPE          =  24_u8 # "\030" # "\x18" # Terminal Type
  OPT_EOR            =  25_u8 # "\031" # "\x19" # End of Record
  OPT_TUID           =  26_u8 # "\032" # "\x1a" # TACACS User Identification
  OPT_OUTMRK         =  27_u8 # "\e"   # "\x1b" # Output Marking
  OPT_TTYLOC         =  28_u8 # "\034" # "\x1c" # Terminal Location Number
  OPT_3270REGIME     =  29_u8 # "\035" # "\x1d" # Telnet 3270 Regime
  OPT_X3PAD          =  30_u8 # "\036" # "\x1e" # X.3 PAD
  OPT_NAWS           =  31_u8 # "\037" # "\x1f" # Negotiate About Window Size
  OPT_TSPEED         =  32_u8 # " "    # "\x20" # Terminal Speed
  OPT_LFLOW          =  33_u8 # "!"    # "\x21" # Remote Flow Control
  OPT_LINEMODE       =  34_u8 # "\""   # "\x22" # Linemode
  OPT_XDISPLOC       =  35_u8 # "#"    # "\x23" # X Display Location
  OPT_OLD_ENVIRON    =  36_u8 # "$"    # "\x24" # Environment Option
  OPT_AUTHENTICATION =  37_u8 # "%"    # "\x25" # Authentication Option
  OPT_ENCRYPT        =  38_u8 # "&"    # "\x26" # Encryption Option
  OPT_NEW_ENVIRON    =  39_u8 # "'"    # "\x27" # New Environment Option
  OPT_EXOPL          = 255_u8 # "\377" # "\xff" # Extended-Options-List

  NULL         =  0_u8
  CR           = 13_u8
  LF           = 10_u8
  EOL          = "\r\n".to_slice
  AYT_RESPONSE = "nobody here but us pigeons\r\n".to_slice

  def initialize(&@write : (Bytes) -> Nil)
    @binary_mode = false
    @suppress_go_ahead = false
    @buffer = Bytes.new(0)
  end

  # Buffering here deals with "un-escaping" according to the TELNET protocol.
  # In the TELNET protocol byte value 255 is special.
  # The TELNET protocol calls byte value 255: "IAC". Which is short for "interpret as command".
  # The TELNET protocol also has a distinction between 'data' and 'commands'.
  #
  # If a byte with value 255 (=IAC) appears in the data, then it must be escaped.
  # Escaping byte value 255 (=IAC) in the data is done by putting 2 of them in a row.
  # So, for example:
  #	Bytes[255] -> Bytes[255, 255]
  # Or, for a more complete example, if we started with the following:
  #	Bytes[1, 55, 2, 155, 3, 255, 4, 40, 255, 30, 20]
  # ... TELNET escaping would produce the following:
  #	Bytes[1, 55, 2, 155, 3, 255, 255, 4, 40, 255, 255, 30, 20]
  # (Notice that each "255" in the original byte array became 2 "255"s in a row.)
  # Buffer here deals with "un-escaping". In other words, it un-does what was shown
  # in the examples.
  # So, for example, it does this:
  #	Bytes[255, 255] -> Bytes[255]
  # And, for example, goes from this:
  #	Bytes[1, 55, 2, 155, 3, 255, 255, 4, 40, 255, 255, 30, 20]
  # ... to this:
  #	Bytes[1, 55, 2, 155, 3, 255, 4, 40, 255, 30, 20]
  def buffer(data) : Bytes
    outp = IO::Memory.new
    inp = IO::Memory.new(@buffer.size + data.size)
    inp.write(@buffer)
    inp.write(data.to_slice)
    inp.rewind

    loop do
      byte = inp.read_byte
      break unless byte

      # Escape byte detected
      if byte == IAC
        # Check we have the indicator byte
        check_byte = inp.read_byte
        if check_byte.nil?
          @buffer = Bytes[byte]
          break
        end

        # Perform the action described by the escape byte
        case check_byte
        when WILL, WONT, DO, DONT
          request_byte = inp.read_byte
          if request_byte.nil?
            @buffer = Bytes[byte, check_byte]
            break
          end

          case check_byte
          when DO
            # respond to "IAC DO x"
            if request_byte == OPT_BINARY
              @binary_mode = true
              @write.call(Bytes[IAC, WILL, OPT_BINARY])
            else
              @write.call(Bytes[IAC, WONT, request_byte])
            end
          when DONT
            # respond to "IAC DON'T x" with "IAC WON'T x"
            @write.call(Bytes[IAC, WONT, request_byte])
          when WILL
            # respond to "IAC WILL x"
            case request_byte
            when OPT_BINARY, OPT_ECHO
              @write.call(Bytes[IAC, DO, request_byte])
            when OPT_SGA
              @suppress_go_ahead = true
              @write.call(Bytes[IAC, DO, request_byte])
            else
              @write.call(Bytes[IAC, DONT, request_byte])
            end
          when WONT
            # respond to "IAC WON'T x"
            @suppress_go_ahead = false if request_byte == OPT_SGA
            @write.call(Bytes[IAC, DONT, request_byte])
          end
        when AYT
          # respond to "IAC AYT" (are you there)
          @write.call(AYT_RESPONSE)
        when SB
          # Start sub-negotiation we want to capture bytes up to SE
          sub_negotiation = IO::Memory.new
          sub_negotiation.write(Bytes[IAC, SB])

          loop do
            sub_byte = inp.read_byte
            if sub_byte.nil?
              @buffer = sub_negotiation.to_slice
              break
            end

            if sub_byte == IAC
              request_byte = inp.read_byte
              if request_byte.nil?
                sub_negotiation.write_byte sub_byte
                @buffer = sub_negotiation.to_slice
                break
              end

              case request_byte
              when IAC
                sub_negotiation.write_byte sub_byte
              when SE
                # TODO:: process sub-negotiation
                break
              else
                # TODO:: maybe we want to write both the sub and request bytes?
                raise "error invalid stream"
              end
            else
              sub_negotiation.write_byte sub_byte
            end
          end
        when IAC
          # A double IAC means this is the data
          outp.write_byte byte
        else
          # discards these bytes
        end
      else
        # data byte
        outp.write_byte byte
      end
    end

    outp.to_slice
  end

  def prepare(command)
    data = IO::Memory.new
    data.write command.to_slice

    # TODO:: Escape characters

    if @binary_mode && @suppress_go_ahead
      # IAC WILL SGA IAC DO BIN send EOL --> CR
      data.write_byte CR
    elsif @suppress_go_ahead
      # IAC WILL SGA send EOL --> CR+NULL
      data.write Bytes[CR, NULL]
    else
      # NONE send EOL --> CR+LF
      data.write EOL
    end

    data.to_slice
  end
end
