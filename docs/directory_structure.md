# Directory Structures

Engine core / drivers makes the assumption that the working directory one level
up from the scratch directory. An example deployment structure:

* Working dir: `/home/engine/core`
* Executable: `/home/engine/core/bin/core`
* Driver repositories: `/home/engine/repositories`
  * ACA Drivers: `/home/engine/repositories/aca-engine-drivers`
* Driver executables: `/home/engine/core/bin/drivers`
  * Samsung driver: `/home/engine/core/bin/drivers/353b53_samsung_display_md_series_cr`

However when developing the structure will look more like:

* Working dir: `/home/steve/aca-engine-drivers`
* Driver repository: `/home/steve/aca-engine-drivers`
* Driver executables: `/home/steve/aca-engine-drivers/bin/drivers`
  * Samsung driver: `/home/engine/core/bin/drivers/353b53_samsung_display_md_series_cr`

The primary difference between production and development is engine core, in production, will be cloning repositories and installing shards as required.
