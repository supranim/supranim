#
# Supranim is a high-performance web framework for building
# web applications and microservices in Nim
#
#   (c) 2026 LGPL-v3-or-later License | Made by Humans from OpenPeeps
#   https://supranim.com | https://github.com/supranim
#

## Ozark models backing Supranim's Laravel-like job queues.
##
## Times are Unix epochs (`BigInt`) so rows stay portable across
## the `psql` and `sqlite` drivers and remain easy to compare and
## order with the query builder. Payloads are JSON documents
## stored as `Text`.
##
## Applications pick these models up through a two-line re-export
## in their own model directory (see the starter template):
##
## .. code-block:: nim
##   import pkg/supranim/queue/model
##   export model
##
## Note: ozark's `newModel` matches field types against the *values*
## of its `DataType` enum, so 64-bit integers are spelled `int8`
## (the value of `BigInt`), not `BigInt`.

import pkg/supranim/model

newModel QueueJobs:
  id {.pk.}: Serial
  queue {.notnull.}: Varchar(64)
  job_name {.notnull.}: Varchar(128)
  payload {.notnull.}: Text
  attempts: Int = 0
  max_tries: Int = 3
  available_at {.notnull.}: int8
  priority: Int = 0
  chain_next: Text
  batch_id: Varchar(64)
  created_at {.notnull.}: int8

newModel FailedQueueJobs:
  id {.pk.}: Serial
  queue {.notnull.}: Varchar(64)
  job_name {.notnull.}: Varchar(128)
  payload {.notnull.}: Text
  attempts: Int = 0
  error {.notnull.}: Text
  failed_at {.notnull.}: int8

newModel QueueBatches:
  id {.pk.}: Serial
  batch_id {.unique, notnull.}: Varchar(64)
  total {.notnull.}: Int
  done: Int = 0
  callback_job: Varchar(128)
  callback_payload: Text
  created_at {.notnull.}: int8
