class Test < Application
  # Specs available
  def index
  end

  # Run a spec
  def create
  end

  # WS watch the output from running specs
  ws "/output" do |socket|
  end
end
