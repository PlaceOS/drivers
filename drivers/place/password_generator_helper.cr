# Password defaults
DEFAULT_PASSWORD_LENGTH            = 6
DEFAULT_PASSWORD_EXCLUDE           = "0Oo1Il`'\\/"
DEFAULT_PASSWORD_MINIMUM_LOWERCASE = 1
DEFAULT_PASSWORD_MINIMUM_UPPERCASE = 0
DEFAULT_PASSWORD_MINIMUM_NUMBERS   = 1
DEFAULT_PASSWORD_MINIMUM_SYMBOLS   = 0

PASSWORD_LOWERCASE_CHARACTERS = ('a'..'z').to_a
PASSWORD_UPPERCASE_CHARACTERS = ('A'..'Z').to_a
PASSWORD_NUMBER_CHARACTERS    = ('0'..'9').to_a
PASSWORD_SYMBOL_CHARACTERS    = ['!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '-', '=', '{', '}', '[', ']', '|', '\\', ':', ';', '"', '\'', '<', '>', ',', '.', '?', '/', '`', '~']

def generate_password(
  length : Int32? = DEFAULT_PASSWORD_LENGTH,
  exclude : String? = DEFAULT_PASSWORD_EXCLUDE,
  minimum_lowercase : Int32? = DEFAULT_PASSWORD_MINIMUM_LOWERCASE,
  minimum_uppercase : Int32? = DEFAULT_PASSWORD_MINIMUM_UPPERCASE,
  minimum_numbers : Int32? = DEFAULT_PASSWORD_MINIMUM_NUMBERS,
  minimum_symbols : Int32? = DEFAULT_PASSWORD_MINIMUM_SYMBOLS
) : String
  length ||= DEFAULT_PASSWORD_LENGTH
  exclude ||= DEFAULT_PASSWORD_EXCLUDE
  minimum_lowercase ||= DEFAULT_PASSWORD_MINIMUM_LOWERCASE
  minimum_uppercase ||= DEFAULT_PASSWORD_MINIMUM_UPPERCASE
  minimum_numbers ||= DEFAULT_PASSWORD_MINIMUM_NUMBERS
  minimum_symbols ||= DEFAULT_PASSWORD_MINIMUM_SYMBOLS

  # Make sure the lenght is at least the minimums
  minimums = minimum_lowercase + minimum_uppercase + minimum_numbers + minimum_symbols
  length = minimums if length < minimums

  characters = [] of Char
  characters = PASSWORD_LOWERCASE_CHARACTERS if minimum_lowercase > 0
  characters += PASSWORD_UPPERCASE_CHARACTERS if minimum_uppercase > 0
  characters += PASSWORD_NUMBER_CHARACTERS if minimum_numbers > 0
  characters += PASSWORD_SYMBOL_CHARACTERS if minimum_symbols > 0
  characters = characters - exclude.chars

  # make sure we have some characters to work with
  if characters.empty?
    characters = (PASSWORD_LOWERCASE_CHARACTERS + PASSWORD_NUMBER_CHARACTERS) - DEFAULT_PASSWORD_EXCLUDE.chars
  end

  password = [] of Char

  # Add the minimums
  minimum_lowercase.times { password << (PASSWORD_LOWERCASE_CHARACTERS - exclude.chars).sample(random: Random::Secure) }
  minimum_uppercase.times { password << (PASSWORD_UPPERCASE_CHARACTERS - exclude.chars).sample(random: Random::Secure) }
  minimum_numbers.times { password << (PASSWORD_NUMBER_CHARACTERS - exclude.chars).sample(random: Random::Secure) }
  minimum_symbols.times { password << (PASSWORD_SYMBOL_CHARACTERS - exclude.chars).sample(random: Random::Secure) }

  # Add the rest
  (length - minimums).times { password << characters.sample(random: Random::Secure) }

  # Shuffle the password
  password.shuffle(random: Random::Secure).join
end
