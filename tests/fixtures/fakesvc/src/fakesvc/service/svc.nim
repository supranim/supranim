# Fixture service provider for testing automatic config install.
# Importing this module expands `initService`, which installs
# `config/probe_fakesvc_install.yml` into the application's `config/`
# directory at compile time (copy-once).
import supranim/core/services

initService FakeSvc[Singleton]:
  backend do:
    type
      FakeSvc = object
        marker: string
  client do:
    proc fakeMarker*(): string = "fake"
