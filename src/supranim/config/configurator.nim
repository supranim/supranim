import nyml
from std/net import Port
from std/nativesockets import Domain

export Port, Domain

type
    AppKey = object
        key: string

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

    DBConfig = object
        main: Database
        secondary: seq[Database]

    Config = object
        app: AppConfig
        database: DBConfig
        services: seq[string]

proc init[C: typedesc[Config]](ymlContents: string): Config =
    ## Initialize a Config instance
    result = Config(app: appConfig, database: DBConfig)