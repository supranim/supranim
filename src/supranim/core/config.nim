# Supranim is a simple MVC-style web framework for building
# fast web applications, REST API microservices and other cool things.
#
# (c) 2021 Supranim is released under MIT License
#          George Lemon | Made by Humans from OpenPeep
#          https://supranim.com   |    https://github.com/supranim

import nyml
from std/net import Port
from std/nativesockets import Domain

export Port, Domain

type
    AppKey = distinct string

    AppConfig = object
        port: Port
        name: string
        key: AppKey
        assets: tuple[source, public: string]

    DBDriver = enum
        PGSQL, MYSQL, SQLITE

    Database = ref object
        port: Port
        driver: DBDriver
        address: Domain.AF_INET
        name: string
        username: string
        password: string

    Database = object
        main: DBCredential
            ## Main database credentials
        secondary: seq[DBCredential]
            ## A sequence of secondary database credentials

    Config = object
        databases: Database
        services: seq[string]

proc init[C: typedesc[Config]](ymlContents: string): Config =
    ## Initialize a Config instance
    result = Config(app: appConfig, database: DBConfig)