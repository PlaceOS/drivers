# Directory Structures

PlaceOS core / drivers makes the assumption that the working directory one level
up from the scratch directory. An example deployment structure:

* Working dir: `/home/placeos/core`
* Executable: `/home/placeos/core/bin/core`
* Driver repositories: `/home/placeos/repositories`
  * PlaceOS Drivers: `/home/placeos/repositories/drivers`
* Driver executables: `/home/placeos/core/bin/drivers`
  * Samsung driver: `/home/placeos/core/bin/drivers/353b53_samsung_display_md_series_cr`

However when developing the structure will look more like:

* Working dir: `/home/steve/drivers`
* Driver repository: `/home/steve/drivers`
* Driver executables: `/home/steve/drivers/bin/drivers`
  * Samsung driver: `/home/placeos/core/bin/drivers/353b53_samsung_display_md_series_cr`

The primary difference between production and development is PlaceOS core, in production, will be cloning repositories and installing shards as required.
