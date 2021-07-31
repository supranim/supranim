**A simple web framework for creating REST APIs and beautiful web apps. Fully written in Nim**
Supranim is also available as a NodeJS addon so it can surely boost your ugly app performances.

## Server Features
- [ ] HTTP/1.1 server
- [ ] Multi-threading 
- [ ] Supports al `verbs` (`GET`, `POST`, `PUT`, `DELETE`...)
- [ ] High Performance & Scalability
- [ ] PostgreSQL Support powered by [Enimsql ORM](https://github.com/georgelemon/enimsql)
- [ ] Static Files & Assets

## Framework Features
If you want the full Supranim experience you can also `nimble install supranim-framework` and you'll get the following extra functionalities:
- [ ] Database `Migrator` / `Schema` / `Model`
- [ ] Middleware Support
- [ ] Session Management
- [ ] Cookie jar
- [ ] Form Validation
- [ ] Authentication System
- [ ] Hot Code Reloading [flag](https://nim-lang.github.io/Nim/hcr.html)

## Supranim CLI
The extendable Command Line Interface which gives you full control to your Supranim server & app, based on [Klymene CLI Toolkit](https://github.com/georgelemon/klymene).

Available Commands in Supranim CLI
```bash
# todo
```


## Quick Examples
Starting a new Supranim server is easy
```python
from supranim import App, Router, Response, Request

proc homepage(resp: var Response): Response =
    ## A simple procedure for returning a Hello World response
    return resp "Hello World!"

# A simple GET route
Router.get("/", homepage)

# Route your own Error pages
Router.e404("Oups! 404 - Not Found")
Router.e500("Oups! 500 - Internal Error")

App(address: "127.0.0.1", port: "3399", ssl: true).run()

```
