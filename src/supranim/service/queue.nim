#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Laravel-like job queues for Supranim applications.
##
## Jobs are defined with the `job` macro in `src/service/event/queue`
## (auto-discovered at compile time, same as event listeners) and
## dispatch rows into the `queue_jobs` table (see `queue/model`).
## A `queue:work` process executes them on a `ThreadPoolService`
## pool via the `service/queue_work` bridge (`startQueueWorker`).
##
## Queue job files must also import an ozark driver (`psql` or
## `sqlite`, same as any app code touching the database) for
## `withDBPool` / `Models`, plus their models:
##
## .. code-block:: nim
##   import pkg/supranim/service/queue
##   import pkg/supranim/queue/model
##   import pkg/ozark/driver/psql
##
##   job SendWelcomeEmail:
##     queue = "emails"
##     tries = 3
##     backoff = 60
##     timeout = 120
##
##     payload:
##       userId: int
##       email: string
##
##     handle(payload):
##       Mailer.sendWelcome(payload.userId, payload.email)
##
## This generates `SendWelcomeEmailPayload`, `handleSendWelcomeEmail`
## and the typed dispatcher `dispatchSendWelcomeEmail(payload, delay = 0,
## onQueue = "emails")`, and registers the job in `QueueRegistry`
## for the worker process.

import std/[macros, macrocache, tables, json, options, times]

export json
export options

type
  QueueJobHandle* = proc(payload: JsonNode) {.closure.}
    ## Untyped entry point used by the worker process: deserializes
    ## the stored payload and calls the typed `handle` proc.
  QueueJobEntry* = object
    queue*: string
    tries*: int
    backoff*: int
    timeout*: int
    handle*: QueueJobHandle

var QueueRegistry* = newTable[string, QueueJobEntry]()
  ## All jobs defined via the `job` macro, keyed by job name.

const QueueJobsRegistry = CacheTable"QueueJobsRegistry"
  ## Compile-time set of job names, used to reject duplicates.

proc queueNowUnix*(): int64 =
  ## Current Unix time, used for `available_at` / `created_at`.
  toUnix(getTime())

macro job*(jobName: untyped, body: untyped): untyped =
  ## Define a typed queue job. Settings are `queue` (default
  ## `"default"`), `tries` (3), `backoff` seconds (60) and `timeout`
  ## seconds (120). The `payload:` block declares `field: Type` pairs
  ## (no defaults in v1); `handle(payload):` holds the job logic.
  jobName.expectKind(nnkIdent)
  body.expectKind(nnkStmtList)
  let
    jobNameStr = jobName.strVal
    payloadTypeIdent = ident(jobNameStr & "Payload")
    dispatchProcIdent = ident("dispatch" & jobNameStr)
  if QueueJobsRegistry.hasKey(jobNameStr):
    error("Duplicate queue job `" & jobNameStr & "`", jobName)
  QueueJobsRegistry[jobNameStr] = newLit(jobNameStr)
  var
    queueName = "default"
    tries = 3
    backoff = 60
    timeout = 120
    payloadFields = newNimNode(nnkRecList)
    handleParam: NimNode = nil
    handleBody: NimNode = nil
  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      if stmt[0].kind != nnkIdent:
        error("Job settings must be `name = value` assignments", stmt)
      case stmt[0].strVal
      of "queue":
        stmt[1].expectKind(nnkStrLit)
        queueName = stmt[1].strVal
      of "tries":
        stmt[1].expectKind(nnkIntLit)
        tries = int(stmt[1].intVal)
      of "backoff":
        stmt[1].expectKind(nnkIntLit)
        backoff = int(stmt[1].intVal)
      of "timeout":
        stmt[1].expectKind(nnkIntLit)
        timeout = int(stmt[1].intVal)
      else:
        error("Unknown job setting `" & stmt[0].strVal &
          "`. Supported: queue, tries, backoff, timeout", stmt)
    of nnkCall:
      if stmt[0].kind != nnkIdent:
        error("Unexpected statement in job `" & jobNameStr & "`", stmt)
      if stmt[0].eqIdent"payload":
        if stmt.len != 2 or stmt[1].kind != nnkStmtList:
          error("`payload:` takes a block of `field: Type` declarations", stmt)
        for f in stmt[1]:
          if f.kind == nnkCall and f.len == 2 and f[0].kind == nnkIdent and
              f[1].kind == nnkStmtList and f[1].len == 1:
            # export the field so `%` / `to` work across modules
            add payloadFields, nnkIdentDefs.newTree(
              nnkPostfix.newTree(ident"*", f[0]), f[1][0], newEmptyNode())
          elif f.kind == nnkCommentStmt:
            discard
          else:
            error("Payload fields must be `name: Type` declarations (no defaults in v1)", f)
      elif stmt[0].eqIdent"handle":
        if stmt.len != 3 or stmt[1].kind != nnkIdent or stmt[2].kind != nnkStmtList:
          error("`handle` takes exactly one parameter, e.g. `handle(payload):`", stmt)
        handleParam = stmt[1]
        handleBody = stmt[2]
      else:
        error("Unknown job block `" & stmt[0].strVal &
          "`. Supported: payload, handle", stmt)
    of nnkCommentStmt: discard
    else:
      error("Unexpected statement in job `" & jobNameStr &
        "`. Supported: queue/tries/backoff/timeout settings, payload:, handle:", stmt)
  if payloadFields.len == 0:
    error("Queue job `" & jobNameStr & "` requires a `payload:` block", body)
  if handleBody.isNil:
    error("Queue job `" & jobNameStr & "` requires a `handle(payload):` block", body)
  # NB: everything below is built with manual AST constructors, no
  # `quote`, so input-derived nodes never cross a quasi-quotation.
  # Every position gets a freshly constructed ident: reusing one
  # NimNode object in several spots corrupts symbol binding.
  let
    tableConstr = nnkTableConstr.newTree(
      nnkExprColonExpr.newTree(newLit"queue", ident"onQueue"),
      nnkExprColonExpr.newTree(newLit"job_name", newLit(jobNameStr)),
      nnkExprColonExpr.newTree(newLit"payload",
        nnkPrefix.newTree(ident"$",
          nnkPrefix.newTree(ident"%", ident"payload"))),
      nnkExprColonExpr.newTree(newLit"attempts", newLit"0"),
      nnkExprColonExpr.newTree(newLit"max_tries", newLit($tries)),
      nnkExprColonExpr.newTree(newLit"available_at",
        nnkPrefix.newTree(ident"$",
          nnkInfix.newTree(ident"+",
            newCall(ident"queueNowUnix"),
            newCall(ident"int64", ident"delay")))),
      nnkExprColonExpr.newTree(newLit"priority", newLit"0"),
      nnkExprColonExpr.newTree(newLit"chain_next", newLit""),
      nnkExprColonExpr.newTree(newLit"batch_id", newLit""),
      nnkExprColonExpr.newTree(newLit"created_at",
        nnkPrefix.newTree(ident"$", newCall(ident"queueNowUnix"))))
    insertExec = newCall(
      nnkDotExpr.newTree(
        newCall(
          nnkDotExpr.newTree(
            newCall(
              nnkDotExpr.newTree(ident"Models", ident"table"),
              ident"QueueJobs"),
            ident"insert"),
          tableConstr),
        ident"exec"))
    dispatchProc = newProc(
      name = nnkPostfix.newTree(ident"*", dispatchProcIdent),
      params = [newEmptyNode(),
        nnkIdentDefs.newTree(ident"payload",
          ident(jobNameStr & "Payload"), newEmptyNode()),
        nnkIdentDefs.newTree(ident"delay", ident"int", newLit(0)),
        nnkIdentDefs.newTree(ident"onQueue", ident"string", newLit(queueName))],
      pragmas = nnkPragma.newTree(ident"discardable"),
      # `withDBPool` injects `sqlDriver` (required by `Models.table`)
      # and runs the insert on a pooled connection
      body = newStmtList(
        newCommentStmtNode("Store one job row for the worker process. " &
          "`delay` postpones availability by seconds, `onQueue` overrides " &
          "the job's queue. Never call from inside another `withDBPool` block."),
        newCall(ident"withDBPool", newStmtList(insertExec))))
    handleProc = newProc(
      name = nnkPostfix.newTree(ident"*", ident("handle" & jobNameStr)),
      params = [newEmptyNode(),
        nnkIdentDefs.newTree(handleParam,
          ident(jobNameStr & "Payload"), newEmptyNode())],
      body = handleBody)
  result = newStmtList(
    nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        nnkPostfix.newTree(ident"*", payloadTypeIdent),
        newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), payloadFields))),
    handleProc,
    dispatchProc,
    newAssignment(
      nnkBracketExpr.newTree(ident"QueueRegistry", newLit(jobNameStr)),
      nnkObjConstr.newTree(ident"QueueJobEntry",
        nnkExprColonExpr.newTree(ident"queue", newLit(queueName)),
        nnkExprColonExpr.newTree(ident"tries", newLit(tries)),
        nnkExprColonExpr.newTree(ident"backoff", newLit(backoff)),
        nnkExprColonExpr.newTree(ident"timeout", newLit(timeout)),
        nnkExprColonExpr.newTree(ident"handle",
          newProc(
            params = [newEmptyNode(),
              nnkIdentDefs.newTree(ident"payloadJson", ident"JsonNode", newEmptyNode())],
            pragmas = nnkPragma.newTree(ident"closure"),
            body = newStmtList(
              newCall(ident("handle" & jobNameStr),
                newCall(ident"to", ident"payloadJson",
                  ident(jobNameStr & "Payload")))))))))
