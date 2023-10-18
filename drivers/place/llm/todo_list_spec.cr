require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::TODOs" do
  exec(:add_task, "my task").get.should eq({
    "complete" => false,
    "task"     => "my task",
  })

  exec(:list_tasks).get.should eq([{
    "complete" => false,
    "task"     => "my task",
  }])

  exec(:complete_task, 0).get.should eq({
    "complete" => true,
    "task"     => "my task",
  })

  exec(:list_tasks).get.should eq([{
    "complete" => true,
    "task"     => "my task",
  }])

  exec(:function_schemas).get.should eq([
    {
      "function"    => "list_tasks",
      "description" => "returns the list of tasks and their current status",
      "parameters"  => {} of String => JSON::Any,
    },
    {
      "function"    => "add_task",
      "description" => "adds a new task to the list",
      "parameters"  => {
        "description" => {"type" => "string", "title" => "String"},
      },
    },
    {
      "function"    => "complete_task",
      "description" => "marks a task as completed",
      "parameters"  => {
        "index" => {"type" => "integer", "format" => "Int32", "title" => "Int32"},
      },
    },
  ])

  # Test the interface
  status[:capabilities].should eq exec(:capabilities).get
  status[:function_schemas].should eq exec(:function_schemas).get
  status[:loaded].should eq(true)
end
