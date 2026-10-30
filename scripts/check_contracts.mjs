#!/usr/bin/env node
import {execFileSync} from "node:child_process"
import {closeSync, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import {basename, dirname, extname, isAbsolute, join, relative, resolve, sep} from "node:path"
import {fileURLToPath} from "node:url"
import {createRequire} from "node:module"

const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), ".."))
/**
 * @cc [owner:ghuntley,label:verification] contract-checker-node-modules
 * The checker MUST load cc-check from OVERALLS_CODE_CONTRACTS_NODE_MODULES when
 * set (the Buck2 check passes the importNpmLock tree of tools/code-contracts),
 * otherwise from tools/code-contracts/node_modules; either way requireCLI
 * still refuses a version that differs from the repository pin.
 */
const nodeModules = process.env.OVERALLS_CODE_CONTRACTS_NODE_MODULES || join(root, "tools/code-contracts/node_modules")
const cli = join(nodeModules, "@spolu/cc-check/dist/cc-check.js")
const require = createRequire(import.meta.url)
const javascriptExtensions = new Set([".js", ".mjs", ".cjs", ".jsx"])
const upstreamExtensions = new Set([".ts", ".tsx", ".mts", ".cts", ".py", ".pyi", ".rs", ".go"])
const nativeExtensions = new Set([".ex", ".exs", ".nix", ".sh", ".c", ".h", ".service", ".slice", ".example", ".kt", ".swift"])
// Languages whose notes are contiguous `//` or `///` line comments.
const slashExtensions = new Set([".kt", ".swift"])

function nativeFile(path) {
  return nativeExtensions.has(extname(path)) || basename(path) === ".envrc"
}

function sourceFile(path) {
  return nativeFile(path) || upstreamExtensions.has(extname(path)) || javascriptExtensions.has(extname(path))
}

function excludedSource(path) {
  return path.split(sep).some(part => ["vendor", "resource_snapshots", "static"].includes(part))
}

function requireCLI() {
  if (!existsSync(cli)) throw new Error("Contract checker is not installed. Run: npm ci --prefix tools/code-contracts --ignore-scripts")
  const requested = JSON.parse(readFileSync(join(root, "tools/code-contracts/package.json"), "utf8")).devDependencies["@spolu/cc-check"]
  const installed = JSON.parse(readFileSync(join(dirname(dirname(cli)), "package.json"), "utf8")).version
  if (requested !== installed) throw new Error("Installed cc-check does not match the repository pin. Run: npm ci --prefix tools/code-contracts --ignore-scripts")
}

function projectedSource(path) {
  return javascriptExtensions.has(extname(path)) ? path + (extname(path) === ".jsx" ? ".tsx" : ".ts") : path
}

function upstreamDocuments(path, source) {
  requireCLI()
  // This source-document interface is version-pinned and exercised by regression
  // tests. Reuse the upstream lexer so strings never masquerade as JSDoc.
  const {extractSourceContractDocuments} = require(join(dirname(cli), "contract-extractors/index.js"))
  return extractSourceContractDocuments(projectedSource(path), source)
}

function projectedPath(path) {
  const parts = path.split(sep)
  return join(...parts.slice(0, -1).map(part => `d-${part}`), parts.at(-1))
}

function regularWithin(directory, path) {
  const parts = path.split(sep)
  if (isAbsolute(path) || parts.some(part => part === "..")) return false
  let current = directory
  for (let i = 0; i < parts.length; i++) {
    current = join(current, parts[i])
    const info = lstatSync(current, {throwIfNoEntry: false})
    if (!info || info.isSymbolicLink()) return false
    if (i < parts.length - 1 && !info.isDirectory()) return false
    if (i === parts.length - 1 && !info.isFile()) return false
  }
  return true
}

/** @param {string} directory @returns {string[]} */
/**
 * @cc [owner:ghuntley,label:verification] inventory-includes-untracked
 * discoverFiles MUST include tracked and nonignored untracked files, deduplicate
 * them, and exclude files with symlink leaves or ancestors so checking does not
 * traverse outside the repository. Inventories exceeding the subprocess output
 * buffer MUST remain complete rather than fail with ENOBUFS or silently truncate.
 */
export function discoverFiles(directory) {
  const temporary = mkdtempSync(join(tmpdir(), "overalls-contract-inventory-"))
  const inventory = join(temporary, "paths")
  const descriptor = openSync(inventory, "wx", 0o600)
  try {
    execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], {cwd: directory, stdio: ["ignore", descriptor, "pipe"]})
    const output = readFileSync(inventory, "utf8")
    return [...new Set(output.split("\0").filter(Boolean))].sort().filter(path => regularWithin(directory, path))
  } finally {
    closeSync(descriptor)
    rmSync(temporary, {recursive: true, force: true})
  }
}

/**
 * @cc [owner:ghuntley,label:verification] native-notes-single-directive
 * Each native source note MUST contain exactly one directive in a contiguous hash
 * comment group, C documentation block or (Kotlin, Swift) contiguous
 * `//`/`///` line-comment group. Extraction MUST retain original line
 * numbers and MUST NOT claim to resolve declarations or their ancestors.
 */
export function extractNativeNotes(path, source) {
  const lines = source.split("\n")
  const groups = []
  if ([".c", ".h"].includes(extname(path))) {
    const pattern = /\/\*\*[\s\S]*?\*\//g
    for (const match of source.matchAll(pattern)) {
      const line = source.slice(0, match.index).split("\n").length
      const body = match[0].slice(3, -2)
      groups.push({line, lines: body.split("\n").map((text, index) =>
        (index === 0 ? text.replace(/^[ \t]+/, "") : text.replace(/^\s*\* ?/, "")).trimEnd())})
    }
  } else if (slashExtensions.has(extname(path))) {
    for (let i = 0; i < lines.length; i++) {
      if (!/^\s*\/\//.test(lines[i])) continue
      const group = {line: i + 1, lines: []}
      while (i < lines.length && /^\s*\/\//.test(lines[i])) {
        group.lines.push(lines[i].replace(/^\s*\/\/\/? ?/, ""))
        i++
      }
      groups.push(group)
    }
  } else {
    for (let i = 0; i < lines.length; i++) {
      if (!/^\s*#/.test(lines[i])) continue
      const group = {line: i + 1, lines: []}
      while (i < lines.length && /^\s*#/.test(lines[i])) {
        group.lines.push(lines[i].replace(/^\s*# ?/, ""))
        i++
      }
      groups.push(group)
    }
  }
  const notes = groups.filter(group => group.lines.some(line => /^\s*@cc(?:\s|$|\[)/.test(line)))
  for (const note of notes) {
    const directives = note.lines.filter(line => /^\s*@cc(?:\s|$|\[)/.test(line))
    if (directives.length !== 1) throw new Error(`${path}:${note.line}: native documentation must contain exactly one @cc directive; separate blocks with a blank line`)
  }
  return notes
}

function directoryContracts(directory, file) {
  const result = []
  let current = dirname(resolve(directory, file))
  while (true) {
    const candidate = join(current, "CONTRACTS")
    const info = lstatSync(candidate, {throwIfNoEntry: false})
    if (info?.isSymbolicLink()) throw new Error(`${relative(directory, candidate)}: directory contracts must not be symlinks`)
    if (info?.isFile()) result.unshift(candidate)
    if (current === directory) break
    const parent = dirname(current)
    if (parent === current || relative(directory, current).startsWith(`..${sep}`)) throw new Error("Target must be inside the repository")
    current = parent
  }
  return result
}

/**
 * @cc [owner:ghuntley,label:verification] validation-upstream-grammar
 * checkFiles MUST send unchanged supported source documents (JavaScript under
 * a temporary TypeScript suffix), directory contracts and normalized native
 * notes to the pinned upstream format command.
 * A nonzero upstream result MUST fail the gate with original source locations.
 */
/**
 * @cc [owner:ghuntley,label:verification] validation-read-only
 * Checking MUST NOT rewrite repository files. Temporary projections MUST be
 * removed on both success and failure; projections MUST NOT become source files.
 */
export function checkFiles(directory, files) {
  requireCLI()
  const staging = mkdtempSync(join(tmpdir(), "overalls-contracts-"))
  const mapping = new Map()
  let nativeNotes = 0
  let sourceDocuments = 0
  let contractFiles = 0
  const stage = (projected, content, original) => {
    const destination = join(staging, projected)
    if (mapping.has(projected)) throw new Error(`Projection collision for ${original}`)
    mkdirSync(dirname(destination), {recursive: true})
    writeFileSync(destination, content)
    mapping.set(projected, original)
  }
  try {
    for (const path of files) {
      if (basename(path) !== "CONTRACTS" && (!sourceFile(path) || excludedSource(path))) continue
      const source = readFileSync(join(directory, path), "utf8")
      // Prefix directories so upstream's vendor/node_modules exclusions cannot
      // silently skip explicitly inventoried directory contracts.
      const namespace = javascriptExtensions.has(extname(path)) ? "repository-js" : "repository"
      let projected = join(namespace, projectedPath(projectedSource(path)))
      let content = source
      if (basename(path) === "CONTRACTS") {
        contractFiles++
        stage(join("repository-js", projectedPath(path)), source, path)
      } else if (nativeFile(path)) {
        const notes = extractNativeNotes(path, source)
        if (notes.length === 0) continue
        nativeNotes += notes.length
        projected = join("native-notes", projectedPath(join(path, "CONTRACTS")))
        const normalized = Array(source.split("\n").length).fill("")
        for (const note of notes) {
          note.lines.forEach((line, i) => { normalized[note.line - 1 + i] = line })
          // A malformed later directive must not be swallowed as the preceding
          // contract's prose. Check every document alone as well as file-wide IDs.
          stage(join("native-documents", projectedPath(join(path, String(note.line), "CONTRACTS"))),
            "\n".repeat(note.line - 1) + note.lines.join("\n"), path)
        }
        content = normalized.join("\n")
      } else {
        if (upstreamDocuments(path, source).length === 0) continue
        sourceDocuments++
      }
      stage(projected, content, path)
    }
    try {
      execFileSync(process.execPath, [cli, "format"], {cwd: staging, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 120_000, maxBuffer: 8 * 1024 * 1024})
    } catch (error) {
      let message = String(error.stderr || error.stdout || error.message)
      for (const [projected, original] of [...mapping].sort((a, b) => b[0].length - a[0].length)) {
        message = message.replaceAll(join(staging, projected), original).replaceAll(projected, original)
      }
      throw new Error(message.trim())
    }
    return {contractFiles, nativeNotes, sourceDocuments}
  } finally {
    rmSync(staging, {recursive: true, force: true})
  }
}

/**
 * @cc [owner:ghuntley,label:verification] coverage-does-not-prove-behavior
 * Coverage MUST require a source-local note or a CONTRACTS file below the root
 * for each maintained source file. Counts MUST NOT be described as evidence of
 * semantic completeness or implementation compliance.
 */
export function coverage(directory, files) {
  const rows = []
  const missing = []
  for (const path of files) {
    if (!sourceFile(path) || excludedSource(path)) continue
    const source = readFileSync(join(directory, path), "utf8")
    const local = nativeFile(path) ? extractNativeNotes(path, source).length : upstreamDocuments(path, source).length
    const scoped = directoryContracts(directory, path).filter(file => dirname(file) !== directory)
    rows.push({path, local, directory: scoped.length ? relative(directory, scoped.at(-1)) : null})
    if (!local && !scoped.length) missing.push(path)
  }
  return {rows, missing}
}

/**
 * @cc [owner:ghuntley,label:verification] native-list-is-file-level
 * listNative MUST show every source note in the selected file and every ancestor
 * directory contract with provenance. It MUST explicitly state that native
 * declaration attachment and called-symbol obligations require manual inspection.
 */
export function listNative(directory, file) {
  validateListTarget(directory, file)
  const output = ["Native source notes: file-level inventory; inspect declaration attachment and callees manually."]
  for (const ancestor of directoryContracts(directory, file)) {
    output.push(`\n=> ${relative(directory, ancestor)} (directory scope) <=\n${readFileSync(ancestor, "utf8").trim()}`)
  }
  for (const note of extractNativeNotes(file, readFileSync(join(directory, file), "utf8"))) {
    output.push(`\n=> ${file}:${note.line} (adjacent source note) <=\n${note.lines.join("\n").trim()}`)
  }
  return output.join("\n")
}

/**
 * @cc [owner:ghuntley,label:verification] javascript-parser-projection
 * JavaScript discovery MUST use byte-identical temporary .ts/.tsx files with the
 * original ancestor CONTRACTS, map paths back to the original files, and remove
 * temporary files. The projection MUST NOT alter repository source or claim
 * runtime type checking; upstream parses declaration attachment only.
 */
export function listJavaScript(directory, file) {
  validateListTarget(directory, file)
  requireCLI()
  const staging = mkdtempSync(join(tmpdir(), "overalls-contract-list-"))
  const projected = projectedSource(file)
  try {
    mkdirSync(join(staging, ".git"))
    for (const ancestor of directoryContracts(directory, file)) {
      const target = join(staging, relative(directory, ancestor))
      mkdirSync(dirname(target), {recursive: true})
      writeFileSync(target, readFileSync(ancestor))
    }
    const target = join(staging, projected)
    mkdirSync(dirname(target), {recursive: true})
    writeFileSync(target, readFileSync(join(directory, file)))
    return execFileSync(process.execPath, [cli, "list", target], {cwd: staging, encoding: "utf8", timeout: 120_000, maxBuffer: 8 * 1024 * 1024})
      .replaceAll(join(staging, projected), file).replaceAll(projected, file).replaceAll(staging + sep, "")
  } finally { rmSync(staging, {recursive: true, force: true}) }
}

/**
 * @cc [owner:ghuntley,label:verification] list-targets-no-symlinks
 * Every listing route MUST reject symlinked source leaves, source ancestors and
 * ancestor CONTRACTS before delegating to either the native or upstream reader.
 */
export function validateListTarget(directory, file) {
  if (!regularWithin(directory, file)) throw new Error("Contract discovery requires a regular source file without symlink ancestors")
  directoryContracts(directory, file)
}

/** @param {string} directory @param {string[]} paths @returns {{contractFiles: number, nativeNotes: number, sourceDocuments: number, covered: number}} */
/**
 * @cc [owner:ghuntley,label:verification] contract-files-mode-ancestry
 * checkNamed MUST check coverage and format for exactly the named source files
 * together with each one's ancestor CONTRACTS, so a source file passes alone
 * exactly when its part of the repository-wide format check passes. It MUST
 * refuse CONTRACTS paths, whose ID uniqueness also depends on descendants, and
 * paths that are not regular files inside the repository.
 */
export function checkNamed(directory, paths) {
  for (const path of paths) {
    if (basename(path) === "CONTRACTS") throw new Error(`${path}: directory contracts are checked with the whole repository (format)`)
    if (!regularWithin(directory, path)) throw new Error(`${path}: not a regular repository file without symlink ancestors`)
  }
  const sources = paths.filter(path => sourceFile(path) && !excludedSource(path))
  if (!sources.length) return {contractFiles: 0, nativeNotes: 0, sourceDocuments: 0, covered: 0}
  const report = coverage(directory, sources)
  if (report.missing.length) throw new Error(`Source files lack local or subtree contracts:\n${report.missing.join("\n")}`)
  const ancestors = new Set(sources.flatMap(path => directoryContracts(directory, path).map(file => relative(directory, file))))
  return {...checkFiles(directory, [...ancestors, ...sources]), covered: report.rows.length}
}

export function main(args) {
  const [command = "format", input, ...extra] = args
  if (command === "files") {
    const counts = checkNamed(root, args.slice(1))
    console.log(`Code contracts passed for ${counts.covered} named source files (${counts.nativeNotes} native notes, ${counts.sourceDocuments} parsed source files, ${counts.contractFiles} ancestor CONTRACTS). Structural checks only.`)
    return
  }
  if (extra.length || !["format", "list", "coverage"].includes(command)) throw new Error("Usage: node scripts/check_contracts.mjs [format | coverage | list <file> | files <path>...]")
  if (command === "list") {
    if (!input) throw new Error("list requires a repository source file")
    const file = relative(root, resolve(input))
    if (isAbsolute(file) || file.startsWith(`..${sep}`) || !existsSync(join(root, file))) throw new Error("Target must be an existing repository source file (native source locations are not supported)")
    validateListTarget(root, file)
    if (nativeFile(file)) console.log(listNative(root, file))
    else if (javascriptExtensions.has(extname(file))) process.stdout.write(listJavaScript(root, file))
    else if (upstreamExtensions.has(extname(file))) {
      requireCLI()
      const output = execFileSync(process.execPath, [cli, "list", join(root, file)], {cwd: root, encoding: "utf8", timeout: 120_000, maxBuffer: 8 * 1024 * 1024})
      process.stdout.write(output)
    } else throw new Error("Use a supported source file; directory CONTRACTS can be read directly")
    return
  }
  if (input) throw new Error(`${command} inspects the whole repository; it takes no path argument`)
  const files = discoverFiles(root)
  const report = coverage(root, files)
  if (command === "coverage") console.log(JSON.stringify(report, null, 2))
  if (report.missing.length) throw new Error(`Source files lack local or subtree contracts:\n${report.missing.join("\n")}`)
  if (command === "format") {
    const counts = checkFiles(root, files)
    console.log(`Code contracts passed: ${counts.contractFiles} CONTRACTS files, ${counts.nativeNotes} native notes, ${counts.sourceDocuments} parsed source files; ${report.rows.length} maintained source files covered. Structural checks only.`)
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)) }
  catch (error) { console.error(error.message); process.exitCode = 1 }
}
