# import supranim/service

# newService App[RouterDealer]:
#   ## Create standalone Router/Dealer service for the application
#   ## itself. This service starts when the app
#   port = 55000
#   description = "Expose application Universal API"
#   commands = [
#     configUpdate
#   ]

#   before:
#     discard

# proc configUpdate() {.command.} =
#   echo "yayaya"
#   server.send("ok")

# runService do:
#   template configUpdate =
#     execConfigUpdate()