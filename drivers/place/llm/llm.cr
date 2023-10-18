require "placeos-driver"
require "placeos-driver/interface/chat_functions"

class Place::LLM < PlaceOS::Driver
  descriptive_name "PlaceOS LLM Interface"
  generic_name :LLM
  description %(an interface for LLMs such as ChatGPT for discovering capabilities)

  default_settings({
    prompt: %(you are an AI assistant in a smart building.
Helping a staff member with every day tasks.
Don't disclose that you're an AI
Skip language that implies regret or apology
say 'I don't know' for unknowns
skip expert disclaimers
no repetitive answers
don't direct to other sources
focus on key points in questions
simplify complex issues with steps
clarify unclear questions before answering
correct errors in previous answers
end with follow up questions where applicable),

    user_hint: "Hi! I'm your workplace assistant.\n" +
               "I can get you instant answers for almost anything as well as perform actions such as booking a meeting room.\n" +
               "How can I help?",
  })

  def on_load
    on_update
  end

  def on_update
    @prompt = setting(String, :prompt)
    @user_hint = setting?(String, :user_hint) || "Hi! I'm your workplace assistant."

    schedule.clear
    schedule.in(5.seconds) { update_prompt }
    schedule.every(5.minutes) { update_prompt }
  end

  getter! user_hint : String
  getter! prompt : String

  def capabilities
    system.implementing(Interface::ChatFunctions).map do |driver|
      {
        id:         driver.module_name,
        capability: driver.capabilities.get.as_s,
      }
    end
  end

  def new_chat
    {
      prompt:       @prompt,
      capabilities: capabilities,
      system_id:    system.id,
    }
  end

  protected def update_prompt
    self[:prompt] = new_chat
    self[:user_hint] = @user_hint
  end
end
