## Runnable Singleton example.
## Build: `clue build examples/services_counter.nim --out:/tmp/counter`
## Run: `/tmp/counter`
import ./services/counter

hit()
hit()
hit()
assert hits() == 3
echo "counter hits: ", hits()
