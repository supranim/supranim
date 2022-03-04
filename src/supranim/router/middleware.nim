proc setNewMiddleware*(middlewares:seq[proc(): void {.nimcall.}]): void =
    ## Procedure for protecting the route in current chain
    ## One or more middleware handlers are accepted via sequence
    ## The order is processed depends on the order is provided.
    var route = self
    route.middlewares = middlewares
    route.hasMiddleware = true