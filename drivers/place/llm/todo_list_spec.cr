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

  exec(:function_schemas).get.should eq({
    "list_tasks" => {} of String => JSON::Any,
    "add_task" => {
      "description" => {"type" => "string", "title" => "String"}
    },
    "complete_task" => {
      "index" => {"type" => "integer", "format" => "Int32", "title" => "Int32"}
    }
  })
end
