macro getCollection(router: object, field: string, hasParams: bool): untyped =
    ## Retrieve a Collection of routes from ``RouterHandler``
    nnkStmtList.newTree(
        nnkIfStmt.newTree(
            nnkElifBranch.newTree(
                nnkInfix.newTree(
                    newIdentNode("=="),
                    newIdentNode(hasParams.strVal),
                    newIdentNode("true")
                ),
                nnkStmtList.newTree(
                    newDotExpr(router, newIdentNode(field.strVal & "Dynam"))
                )
            ),
            nnkElse.newTree(
                nnkStmtList.newTree(
                    newDotExpr(router, newIdentNode(field.strVal))
                )
            )
        )
    )