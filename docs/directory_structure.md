# Directory Structures

[PlaceOS Core](https://github.com/PlaceOS/core) and [PlaceOS Driver Spec Runner](https://github.com/PlaceOS/driver-spec-runner) make the assumption that the working directory is one level
up from the `drivers` directory.

An example deployment structure:

* Working directory: `/home/placeos/core`
* Executable: `/home/placeos/core/bin/core`
* Driver repositories: `/home/placeos/repositories`
  * PlaceOS Drivers: `/home/placeos/repositories/drivers`
* Driver executables: `/home/placeos/core/bin/drivers`
  * Samsung driver: `/home/placeos/core/bin/drivers/353b53_samsung_display_md_series_cr`

However when developing the structure will look more like:

* Working directory: `/home/placeos/drivers`
* Driver repository: `/home/placeos/drivers`
* Driver executables: `/home/placeos/drivers/bin/drivers`
  * Samsung driver: `/home/placeos/core/bin/drivers/353b53_samsung_display_md_series_cr`

The primary difference between production and development is [PlaceOS Core](https://github.com/PlaceOS/core).
In a production environment, PlaceOS Core handles cloning repositories, installing packages, and building Drivers as required.
