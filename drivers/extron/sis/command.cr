# Structure for representing a SIS device command.
#
# Commands are composed from a set of *fields*. The contents and types of these
# are arbitrary, however they must be capable of serialising to an IO.
struct Extron::SIS::Command(*T)
  def initialize(*fields : *T)
    @fields = fields
  end

  # Serialises `self` in a format suitable for log messages.
  def to_s(io : IO)
    io << '‹'
    to_io io
    io << '›'
  end

  # Writes `self` to the passed *io*.
  def to_io(io : IO, format = IO::ByteFormat::SystemEndian)
    @fields.each.flatten.each do |field|
      if field.is_a? Enum
        io.write_byte field.value
      else
        io << field
      end
    end
  end

  # Syntactical suger for `Command` definition. Provides the ability to express
  # command fields in the same way as `Byte` objects and other similar
  # collections from the Crystal std lib.
  macro [](*fields)
    Extron::SIS::Command.new({{*fields}})
  end
end
