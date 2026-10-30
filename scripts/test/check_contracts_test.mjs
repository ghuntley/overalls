import assert from "node:assert/strict"
import {mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync} from "node:fs"
import {execFileSync} from "node:child_process"
import {tmpdir} from "node:os"
import {dirname, join} from "node:path"
import {test} from "node:test"
import {checkFiles, checkNamed, coverage, discoverFiles, extractNativeNotes, listNative, listJavaScript, validateListTarget} from "../check_contracts.mjs"

function fixture(files, run) {
  const root = mkdtempSync(join(tmpdir(), "overalls-contract-test-"))
  try {
    for (const [path, body] of Object.entries(files)) {
      mkdirSync(dirname(join(root, path)), {recursive: true})
      writeFileSync(join(root, path), body)
    }
    return run(root, Object.keys(files))
  } finally { rmSync(root, {recursive: true, force: true}) }
}

const directive = "@" + "cc"
const contract = `${directive} [owner:ghuntley,label:verification] unchanged\nFailure MUST leave state unchanged.\n`
const hashNote = contract.trimEnd().split("\n").map(line => `# ${line}`).join("\n")

test("native extraction preserves lines and ignores ordinary comments", () => {
  const source = `# purpose\ndefmodule A do\n  ${hashNote.replaceAll("\n", "\n  ")}\n  def run, do: :ok\nend\n`
  assert.deepEqual(extractNativeNotes("a.ex", source), [{line: 3, lines: contract.trimEnd().split("\n")}])
})

test("native and C notes use upstream grammar without rewriting files", () => {
  const cNote = `/**\n * ${contract.trimEnd().replaceAll("\n", "\n * ")}\n */\nint main(void) {return 0;}\n`
  fixture({"a.nix": `${hashNote}\n{}\n`, "b.c": cNote}, (root, paths) => {
    const before = paths.map(path => readFileSync(join(root, path), "utf8"))
    assert.equal(checkFiles(root, paths).nativeNotes, 2)
    assert.deepEqual(paths.map(path => readFileSync(join(root, path), "utf8")), before)
  })
})

test("Kotlin and Swift notes are contiguous slash comment groups", () => {
  const slashNote = contract.trimEnd().split("\n").map(line => `  /// ${line}`).join("\n")
  const source = `class A {\n  // ordinary\n\n${slashNote}\n  void run() {}\n}\n`
  for (const path of ["A.kt", "A.swift"]) {
    assert.deepEqual(extractNativeNotes(path, source), [{line: 4, lines: contract.trimEnd().split("\n")}])
  }
  assert.throws(() => extractNativeNotes("A.kt", `${slashNote}\n${slashNote}`), /exactly one/)
  fixture({"A.kt": source}, (root, paths) => assert.equal(checkFiles(root, paths).nativeNotes, 1))
})

test("native block rejects multiple directives", () => {
  assert.throws(() => extractNativeNotes("a.ex", `${hashNote}\n${hashNote}`), /exactly one/)
})

test("upstream rejects malformed metadata at original source location", () => {
  fixture({"a.ex": `defmodule A do\n\n# ${directive} [owner:bad name] bad\n# MUST fail.\nend\n`}, (root, paths) => {
    assert.throws(() => checkFiles(root, paths), /a\.ex:3:/)
  })
})

test("upstream rejects empty native prose and repeated file-local IDs", () => {
  fixture({"a.ex": `# ${directive} empty\ndef run, do: :ok\n`}, (root, paths) => assert.throws(() => checkFiles(root, paths)))
  fixture({"a.ex": `${hashNote}\ndef one, do: :ok\n\n${hashNote}\ndef two, do: :ok\n`}, (root, paths) => assert.throws(() => checkFiles(root, paths), /not unique/))
})

test("ancestor duplicate IDs fail but sibling directory IDs may repeat", () => {
  fixture({CONTRACTS: contract, "sub/CONTRACTS": contract}, (root, paths) => assert.throws(() => checkFiles(root, paths), /not unique/))
  fixture({"one/CONTRACTS": contract, "two/CONTRACTS": contract}, (root, paths) => assert.equal(checkFiles(root, paths).contractFiles, 2))
})

test("native discovery includes ancestors and all notes with honest scope", () => {
  fixture({CONTRACTS: contract, "sub/CONTRACTS": contract.replace("unchanged", "subrule"), "sub/a.ex": hashNote}, root => {
    const output = listNative(root, "sub/a.ex")
    assert.match(output, /file-level inventory/)
    assert.match(output, /CONTRACTS \(directory scope\)/)
    assert.match(output, /sub\/CONTRACTS/)
    assert.match(output, /sub\/a.ex:1/)
  })
})

test("root governance alone is insufficient source coverage", () => {
  fixture({CONTRACTS: contract, "a.ex": "defmodule A do\nend\n", "sub/CONTRACTS": contract, "sub/b.nix": "{}"}, (root, paths) => {
    assert.deepEqual(coverage(root, paths).missing, ["a.ex"])
  })
})

test("supported JSDoc uses official source validation", () => {
  const js = `/**\n * ${contract.trimEnd().replaceAll("\n", "\n * ")}\n */\nexport function run() {}\n`
  fixture({"a.mjs": js}, (root, paths) => assert.equal(checkFiles(root, paths).sourceDocuments, 1))
})

test("JavaScript projection rejects malformed and duplicate declaration contracts", () => {
  const malformed = `/** ${directive} [owner:bad name] bad\n * MUST reject.\n */\nexport function run() {}\n`
  fixture({"a.mjs": malformed}, (root, paths) => assert.throws(() => checkFiles(root, paths), /a\.mjs:1:/))
  const doc = `/**\n * ${contract.trimEnd().replaceAll("\n", "\n * ")}\n */\n`
  fixture({"a.js": doc + doc + "function run() {}\n"}, (root, paths) => assert.throws(() => checkFiles(root, paths), /not unique within its declaration/))
})

test("JavaScript discovery returns real declarations and inherited contracts", () => {
  const js = `export class Input {\n/**\n * ${contract.trimEnd().replaceAll("\n", "\n * ")}\n */\nreset() {}\n}\n`
  fixture({CONTRACTS: contract.replace("unchanged", "ancestor"), "sub/a.mjs": js}, root => {
    const output = listJavaScript(root, "sub/a.mjs")
    assert.match(output, /ancestor/)
    assert.match(output, /unchanged/)
    assert.match(output, /method.*reset/)
    assert.match(output, /sub\/a.mjs/)
    assert.doesNotMatch(output, /a\.mjs\.ts/)
  })
})

test("contract-looking strings and ordinary comments cannot satisfy source coverage", () => {
  fixture({"a.js": `const text = ${JSON.stringify(contract)};\n// ${directive} ordinary\n`, "b.py": `text = ${JSON.stringify(contract)}\n`}, (root, paths) => {
    assert.deepEqual(coverage(root, paths).missing, paths)
    assert.equal(checkFiles(root, paths).sourceDocuments, 0)
  })
})

test("directory contracts inside vendor are still validated with ancestry", () => {
  fixture({"vendor/CONTRACTS": `${directive} [owner:bad name] bad\nInvalid metadata.\n`}, (root, paths) => assert.throws(() => checkFiles(root, paths), /vendor\/CONTRACTS:1:/))
  fixture({CONTRACTS: contract, "vendor/sub/CONTRACTS": contract}, (root, paths) => assert.throws(() => checkFiles(root, paths), /not unique/))
})

test("symlinked CONTRACTS cannot provide unvalidated inherited coverage", () => {
  fixture({"external": contract, "sub/a.ex": "defmodule A do\nend\n"}, root => {
    symlinkSync(join(root, "external"), join(root, "sub/CONTRACTS"))
    assert.throws(() => coverage(root, ["sub/a.ex"]), /must not be symlinks/)
    assert.throws(() => listNative(root, "sub/a.ex"), /must not be symlinks/)
  })
})

test("Git inventory includes untracked sources but never traverses symlink parents", () => {
  fixture({"sub/tracked.ex": "defmodule A do\nend\n", "untracked.nix": "{}\n"}, root => {
    execFileSync("git", ["init", "--quiet"], {cwd: root})
    execFileSync("git", ["add", "sub/tracked.ex"], {cwd: root})
    assert.deepEqual(discoverFiles(root), ["sub/tracked.ex", "untracked.nix"])
    rmSync(join(root, "sub"), {recursive: true})
    mkdirSync(join(root, "outside"))
    writeFileSync(join(root, "outside/tracked.ex"), "defmodule External do\nend\n")
    symlinkSync(join(root, "outside"), join(root, "sub"))
    assert.ok(!discoverFiles(root).includes("sub/tracked.ex"))
  })
})

test("Git inventory remains complete beyond the default subprocess output buffer", () => {
  const prefix = Array.from({length: 4}, () => "review-directory-".repeat(12)).join("/")
  const files = Object.fromEntries(Array.from({length: 1500}, (_, index) => [`${prefix}/${index}.ex.md`, "review"]))
  assert.ok(Buffer.byteLength(Object.keys(files).join("\0")) > 1024 * 1024)
  /** @param {string} root */
  const verify = root => {
    execFileSync("git", ["init", "--quiet"], {cwd: root})
    assert.deepEqual(discoverFiles(root), Object.keys(files).sort())
  }
  fixture(files, verify)
})

test("malformed later native directives cannot be absorbed into previous prose", () => {
  fixture({"a.ex": `${hashNote}\ndef first, do: :ok\n\n# ${directive}[owner:ghuntley] malformed\n# MUST reject.\ndef second, do: :ok\n`}, (root, paths) => {
    assert.throws(() => checkFiles(root, paths), /a\.ex:5:/)
  })
})

test("JavaScript projection cannot overwrite an existing TypeScript filename", () => {
  fixture({"a.js": `/** ${directive} [owner:bad name] bad\n * MUST reject.\n */\nfunction run() {}\n`, "a.js.ts": "function other() {}\n"}, (root, paths) => assert.throws(() => checkFiles(root, paths), /a\.js:1:/))
})

test("C documentation accepts a directive on its opening line", () => {
  fixture({"a.c": `/** ${directive} [owner:ghuntley] first-line\n * A failed operation MUST leave state unchanged.\n */\nint main(void) {return 0;}\n`}, (root, paths) => assert.equal(checkFiles(root, paths).nativeNotes, 1))
})

test("every list route rejects internal directory links and linked ancestor contracts", () => {
  fixture({"real/a.py": "def run():\n    pass\n", "real/b.mjs": "function run() {}\n", "real/c.ex": "defmodule A do\nend\n", "rules": contract}, root => {
    symlinkSync(join(root, "real"), join(root, "alias"))
    for (const path of ["alias/a.py", "alias/b.mjs", "alias/c.ex"]) {
      assert.throws(() => validateListTarget(root, path), /without symlink ancestors/)
    }
    symlinkSync(join(root, "rules"), join(root, "real/CONTRACTS"))
    assert.throws(() => validateListTarget(root, "real/a.py"), /must not be symlinks/)
    assert.throws(() => listJavaScript(root, "real/b.mjs"), /must not be symlinks/)
    assert.throws(() => listNative(root, "real/c.ex"), /must not be symlinks/)
  })
})

test("named-file checks include ancestor CONTRACTS and refuse directory contracts", () => {
  const other = hashNote.replace("unchanged", "other")
  fixture({CONTRACTS: contract, "sub/CONTRACTS": contract, "sub/a.ex": other}, root => {
    assert.throws(() => checkNamed(root, ["sub/a.ex"]), /not unique/)
    assert.throws(() => checkNamed(root, ["sub/CONTRACTS"]), /checked with the whole repository/)
  })
  fixture({CONTRACTS: contract, "sub/a.ex": other, "b.ex": "defmodule B do\nend\n", "README.md": "text"}, root => {
    assert.equal(checkNamed(root, ["sub/a.ex"]).covered, 1)
    assert.equal(checkNamed(root, ["README.md"]).covered, 0)
    assert.throws(() => checkNamed(root, ["b.ex"]), /lack local or subtree contracts/)
    assert.throws(() => checkNamed(root, ["missing.ex"]), /not a regular repository file/)
  })
})
