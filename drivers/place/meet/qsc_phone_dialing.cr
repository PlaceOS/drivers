# Code for handling QSC phone dialing, if available
module Place::QSCPhoneDialing
  # This data will be stored in the tab
  class QscPhone
    include JSON::Serializable

    getter number_id : String
    getter dial_id : String
    getter hangup_id : String
    getter status_id : String
    getter ringing_id : String
    getter offhook_id : String
    getter dtmf_id : String
  end

  macro included
    {% EXT_INIT << :qsc_phone_dialing_init %}
    {% EXT_POWER << :qsc_phone_dialing_power %}
  end

  @qsc_dial_settings : QscPhone? = nil
  @dial_string : String = ""

  protected def qsc_phone_dialing_init
    @qsc_dial_settings = setting?(QscPhone, :qsc_phone)
    self[:qsc_dial_number] = @dial_string
    self[:qsc_dial_bindings] = @qsc_dial_settings
  end

  protected def qsc_phone_dialing_power(state : Bool, unlink : Bool)
    if state
      qsc_dial_pad_clear
    else
      qsc_dial_hangup
      qsc_dial_pad_clear
    end
  end

  protected def qsc_dial_pad_sync : Nil
    dial_settings = @qsc_dial_settings
    return unless dial_settings
    system[:Mixer].set_string(dial_settings.number_id, @dial_string)
    self[:qsc_dial_number] = @dial_string
  end

  def qsc_dial_pad(number : String)
    return unless number.size > 0
    char = number[0]

    case char
    when '\b'
      @dial_string = @dial_string[0..-2] unless @dial_string.size == 0
    when '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '#'
      @dial_string = "#{@dial_string}#{char}"
    else
      logger.info { "unsupported dial char provided #{char}" }
    end

    qsc_dial_pad_sync
  end

  def qsc_dial_pad_clear : Nil
    @dial_string = ""
    qsc_dial_pad_sync
  end

  def qsc_dial_makecall
    dial_settings = @qsc_dial_settings
    return unless dial_settings
    system[:Mixer].trigger(dial_settings.dial_id)
  end

  def qsc_dial_hangup
    dial_settings = @qsc_dial_settings
    return unless dial_settings
    system[:Mixer].trigger(dial_settings.hangup_id)
  end
end
