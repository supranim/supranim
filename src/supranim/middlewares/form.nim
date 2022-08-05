import ./middleware
import ../support/csrf

proc csrf*(req: Request, res: var Response): bool =
    ## TODO