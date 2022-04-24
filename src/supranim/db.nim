import enimsql

type
    DBDriver = enum
        PGSQL, MYSQL, SQLITE

    DBCredentials = seq[tuple[key, val: string]]
    
    Database = ref object
        port: Port
        driver: DBDriver
        address: Domain
        name: string
        username: string
        password: string

    DBConfig = object
        main: Database
        secondary: seq[Database]

type
    Client* = object of Model
        bookings*: string
        courtesy*: string
        first_name*: string
        last_name*: string
        country*: string
        primary_phone*: string
        secondary_phone*: string
        email_address*: string
        agency*: string
        primary_address*: string
        secondary_address*: string
        city*: string
        zipcode*: string
        created_at*: string
        updated_at*: string

proc testDb() =
    let rows = waitFor Client.select("*").where("full_name", "Sandrine Amar").exec()
    for row in rows:
        echo %*(row)
        echo row.get("id")
        # echo row.get("name")