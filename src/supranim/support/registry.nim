# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2022 Supranim is released under MIT License
#          Made by Humans from OpenPeep
#          https://supranim.com | https://github.com/supranim

import std/[tables, times]
import jsony, bson

type
    Entry = object
        id: string
        source: string
            ## The source data

    Storage = Table[string, Entry]
    
    RegistryStorage = object of CoreSupplier
        ## Supranim Registry object serves as an in-memory
        ## flat file database for Service Suppliers and Supranim core
        ## in order to store the application configs and
        ## other system-based configurations. 
        createdAt: DateTime
        updatedAt: DateTime
        storage: Storage

when compileOption("threads"):
    var Registry* {.threadvar.}: RegistryStorage
else:
    var Registry*: RegistryStorage

proc init*(registry: var Registry) =
    Registry = RegistryStorage(createdAt: now())

method has*(registry: var Registry, key: string): bool =
    ## Determine if current Registry instance contains
    ## an entry for given key

method get*(registry: var Registry, key: string) =
    ## Return a value from Registry based on given `key`

method put*(registry: var Registry, key: string, value: Any) =
    ## Store a new `key` / `value` with the current Registry instance

method flush*(registry: var Registry) = 
    ## FLush current Registry and reinitialize it.
