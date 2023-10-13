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
correct errors in previous answers),
  })

  def on_load
    on_update
  end

  def on_update
    @prompt = setting(String, :prompt)
  end

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
end
