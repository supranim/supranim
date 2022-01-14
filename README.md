<p align="center"><img src="/.github/supranim.png" width="180px"><br>
<strong>A simple web framework for creating REST APIs and beautiful web apps. Fully written in Nim</strong>,<br>Supranim is a happy fork of <code>httpbeast</code>, providing extra functionalities, a command line interface, a stupid simple project structure and clean logic.
</p>

**Supranim is an WIP library, so most of these specs are just part of the concept.**

## Server Features
- [x] HTTP/1.1 server
- [x] Multi-threading 
- [x] Supports al `verbs` (`GET`, `POST`, `PUT`, `DELETE`...)
- [x] High Performance & Scalability
- [x] PostgreSQL Support powered by [Enimsql ORM](https://github.com/georgelemon/enimsql)
- [x] Static Files & Assets

## Framework Features
If you want the full Supranim experience you can also `nimble install supranim-framework` and you'll get the following extra functionalities:
- [ ] Database `Migrator` / `Schema` / `Model`
- [ ] Middleware Support
- [ ] Cache Management (`Memcache` and `Redis` Driver)
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
Creating a new Supranim server is easy

```python
from supranim import App, Router, Response, Request, UrlParams

proc AuthMiddleware(): void =
    ## Sample Auth Middleware
    discard

proc homepage(resp: var Response): Response =
    ## A simple procedure for returning a Hello World response
    return resp "Hello World!"

proc aboutUs(resp: var Response): Response =
    ## A simple procedure returning a response for a secondary page
    return resp "This is about us"

proc yourOrder(resp: var Response, req: var Request, params: var UrlParams): Response =
    ## A simple procedure for a route that is middleware-protected,
    ## So, before we call this proc will execute the given middleware.
    ## Also, if provided, it will pass as a 3rd argument an varargs
    ## with available URL parameters
    return resp "Your Order No. #$1" % [ params[0] ]

proc error404(resp: var Response, req: var Request): Response =
    ## A simple procedure for handling 404 errors
    return resp Http404, "404 - Not Found | Sorry, page does not exist"

proc error500(resp: var Response, req: var Request): Response =
    ## A simple procedure for handling 500 errors
    return resp Http404, "500 - Internal Error"


Router.get("/", homepage)
Router.get("/about", aboutUs)
# A route can be protected by providing one or more Middlewares.
# Processing middlewares is done in the order you provide them.
Router.get("/orders/{:id}", yourOrders).middleware(@[AuthMiddleware])

# Routing Assets via Proxy Handler
# Where first parameter must be the relative path to your assets directory,
# and the second one the route for ascessing public files
Router.assets("assets", "media")
# One or more Assets Proxies can be provided to route your assets.
# Let's say we want a route to be available for accessing only by logged in users
Router.assets("private-assets", "private").middleware(@[AuthMiddleware])

# Route your own Error pages
Router.e404(error404)
Router.e500(error500)

App(
    # Server address and port number
    # (Default 127.0.0.1:3399)
    address: "127.0.0.1",
    port: "3399",
    # Boot your app under SSL connection.
    # If set true, it will automatically generate a self-signed
    # SSL certificate (in case it does not exist)
    ssl: true,
    # Enable multi threading support for your Supranim,
    # by allocating one or more from available threads.
    threads: 2,
    # Relative path to your assets directory
    # Used by Assets Proxy Handler for routing
    # your assets to public network
    assets: "../../static"
).run()

```

# Database & Model
By default Supranim works only with PostgreSQL databases via Enimsql ORM. If you want to use MySQL or SQLite or others, you'll have to find a compatible ORM or use it directly via built-in Nim's modules.

**Defining a Database Model is easy.**<br>
By default, each Model will automatically have an 'id' column set as PRIMARY KEY. If you want a custom named column you can simply set with the `{.pk.}` pragma

Also, all columns are by default set as NOT NUL. If you want to set a column as NULL, you can make use of the `{.default_nil.}` pragma.

```python
from supranim import Model, ModelWarnings
from supranim/types import HasherType, TokenType, PKType

# Create Schema for your model
type
    User* = ref object of Model
        id {.pk.}: PKType                       # PKType generates UUID on backend side.
        email* {.unique.}: string               # Set as text with UNIQUE value
        username* {.unique.}: string            # Set as text with UNIQUE value
        display_name* {.default_nil.}: string   # Set as text, and default NULL
        token*: TokenType                       # Set as varchar(64)
        password*: HasherType                   # Set as password
        confirmed* {.default_false.}: bool      # Set as boolean type, default to FALSE

```

**[Read Enimsql documentation](https://github.com/supranim/enimsql) and other tips and tricks.** 

Example of creating a new user account using `User` model from above
```python
from app/models import User

var model = User(email:"test@example.com", username: "georgelemon", password: "123")
var results = model.insertGetOrFail()

if result.hasErrors:
    # Print errors in case something goes wrong
    echo result.showErrors
else:
    # Once created, we can retrieve the newly user details
    var userInfo = result.get("email", "username", "confirmed")
    echo "A new account has been successfully created: " & $userInfo

```

## Supranim Macros
There are tons of macros out of box, these are some of them

```python
echo isLoggedin ? "yes" ! "no"

# Can also handle one or more grouped conditional statements
echo isLoggedin ? "hello " (isAdmin ? "admin" ! "user") ! "hey guest"
```

## Cache Management
Currently there are only 2 cache drivers, `Memcache` and a driver for your `Redis` instance.

**Using Memcache** is one of the fastest way for caching

```python
from supranim/cache import Memcache as Cache

echo Cache.has("sample") ? Cache.get("sample") ! Cache.setAndGet("sample", "Hello cached World")
```

## Session Management
...

## Helpers
There are plenty helpers built around Supranim. A very useful one is `validator/str`, which can validate any string against provided type.

The String Validator provides multiple validating procedures, whereas `isEmail` and `isTLD` are one of the most useful. **In order to keep your spam to minimal we'll validate an email address not just by checking for a valid syntax but also by reachablity and of course, if email does really exist.**
```python
import validator/str

# Catch an syntax invalid e-mail address
var invalidEmail = str.isEmail("typo@example.com.")
assert invalidEmail == "invalid_syntax" # true

# Catching an non reachable e-mail address by specifying an invalid TLD
# will trigger isTLD and return "invalid_tld"
var nonExisting = str.isEmail("whatever@example.coms")
assert nonExisting == "invalid_tld" # true

# Catch an non reachable e-mail address
var nonExisting = str.isEmail("whatever@example.com")
assert nonExisting == "invalid" # true

# A good e-mail address, valid, reachable
var correctEmail = str.isEmail("contact@github.com")
assert correctEmail == "valid" # true

```

`isTLD` procedure will check through a long list with known Top Level Domains to determine if given domain is valid or not.

### Foot notes
**What's Nim?**
_Nim is a statically typed compiled systems programming language. It combines successful concepts from mature languages like Python, Ada and Modula. [Find out more about Nim and Nimble](https://nim-lang.org/)_

**Why Nim?**
Performance, fast compilation and C-like freedom. I want to keep code clean, readable, concise, and close to my intention. Also a very good language to learn in 2021.

# License
Supranim is an open source web framework for developing fast REST API services and beautiful applications. Fully written in `Nim` & Released under `MIT` license.
