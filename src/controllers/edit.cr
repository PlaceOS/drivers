class Edit < Application
  # list of drivers and specs
  def index
  end

  # contents of a driver or spec
  def show
  end

  # create a new driver
  def create
  end

  # update an existing driver or spec
  def update
  end

  # delete a driver or spec
  def delete
  end

  # commits changes to the upstream repo
  post "/commit" do
  end
end
