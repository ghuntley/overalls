// Probe entry for esbuild_bundle: the import must be inlined in the bundle.
import { greeting } from "./greeting.mjs"

console.log(greeting("buck2"))
