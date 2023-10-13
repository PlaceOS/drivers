require "placeos-driver"
require "placeos-driver/interface/chat_functions"

class Place::TODOs < PlaceOS::Driver
  include Interface::ChatFunctions

  descriptive_name "PlaceOS TODO list"
  generic_name :TODO
  description %(an example driver providing functions to a LLM)

  @todos = [] of NamedTuple(complete: Bool, task: String)

  def capabilities : String
    "manages the list of tasks a user needs to complete throughout the day"
  end

  @[Description("returns the list of tasks and their current status")]
  def list_tasks
    @todos
  end

  @[Description("adds a new task to the list")]
  def add_task(description : String)
    task = {complete: false, task: description}
    @todos << task
    task
  end

  @[Description("marks a task as completed")]
  def complete_task(index : Int32)
    task = @todos[index]
    @todos[index] = {complete: true, task: task[:task]}
  end
end
