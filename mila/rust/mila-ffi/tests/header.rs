//! The committed C header is the only description of mila-ffi's C ABI that
//! Apple's `MilaFFIShim` and C callers compile against (ADR-0273). It is written
//! by hand, so these tests keep it equal to the crate: exactly the exported
//! `mila_*` functions, each with its Rust arity, the enumerators of every
//! public C enum at the Rust discriminants, and every declaration inside the
//! include guard.
#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a malformed header or source must fail these tests loudly"
)]
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Function name to parameter count.
type Signatures = BTreeMap<String, usize>;

/// C enum name, the enumerator prefix the header uses, and the Rust enum.
const ENUMS: [(&str, &str); 4] = [
    ("MilaFfiStatus", "MILA_FFI_"),
    ("MilaThreadCommandKind", "MILA_THREAD_"),
    ("MilaMachineCommandKind", "MILA_MACHINE_"),
    ("MilaWatchEventKind", "MILA_WATCH_"),
];

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn header() -> String {
    fs::read_to_string(crate_root().join("include/mila_ffi.h")).expect("read include/mila_ffi.h")
}

/// Every `.rs` file under `src/`, in a stable order.
fn rust_sources() -> Vec<String> {
    fn walk(directory: &Path, files: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(directory).expect("read source directory") {
            let path = entry.expect("source entry").path();
            if path.is_dir() {
                walk(&path, files);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                files.push(path);
            }
        }
    }
    let mut files = Vec::new();
    walk(&crate_root().join("src"), &mut files);
    files.sort();
    files
        .iter()
        .map(|path| fs::read_to_string(path).expect("read Rust source"))
        .collect()
}

/// The text between the parenthesis that opens at the start of `text` and
/// its matching close.
fn parenthesised(text: &str) -> &str {
    let mut depth = 0_usize;
    for (index, character) in text.char_indices() {
        match character {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return text.get(1..index).expect("parameter list");
                }
            }
            _ => {}
        }
    }
    panic!("unbalanced parameter list");
}

/// Top-level comma-separated parameters, ignoring a trailing comma and C's
/// `void`.
fn arity(parameters: &str) -> usize {
    let mut depth = 0_usize;
    let mut count = 0_usize;
    let mut current = String::new();
    for character in parameters.chars() {
        match character {
            '(' | '<' | '[' => depth += 1,
            ')' | '>' | ']' => depth -= 1,
            ',' if depth == 0 => {
                if !current.trim().is_empty() {
                    count += 1;
                }
                current.clear();
                continue;
            }
            _ => {}
        }
        current.push(character);
    }
    let last = current.trim();
    if !last.is_empty() && last != "void" {
        count += 1;
    }
    count
}

/// Exported functions: `extern "C" fn mila_*` after `#[no_mangle]`.
fn exported() -> Signatures {
    let mut signatures = Signatures::new();
    for source in rust_sources() {
        for (index, _) in source.match_indices("#[no_mangle]") {
            let rest = source.get(index..).expect("source tail");
            let Some(start) = rest.find("extern \"C\" fn ") else {
                continue;
            };
            let after = rest
                .get(start + "extern \"C\" fn ".len()..)
                .expect("function name");
            let name: String = after
                .chars()
                .take_while(|character| character.is_alphanumeric() || *character == '_')
                .collect();
            if !name.starts_with("mila_") {
                continue;
            }
            let open = after.find('(').expect("parameter list");
            let parameters = parenthesised(after.get(open..).expect("parameters"));
            signatures.insert(name, arity(parameters));
        }
    }
    signatures
}

/// Declared functions: every `mila_*(` outside comments and preprocessor
/// lines.
fn declared(header: &str) -> Signatures {
    let mut code = String::new();
    let mut rest = header;
    while let Some(start) = rest.find("/*") {
        code.push_str(rest.get(..start).expect("code before comment"));
        let end = rest
            .get(start..)
            .and_then(|tail| tail.find("*/"))
            .expect("closed comment");
        rest = rest.get(start + end + 2..).expect("code after comment");
    }
    code.push_str(rest);
    let code: String = code
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    let mut signatures = Signatures::new();
    for (index, _) in code.match_indices("mila_") {
        let preceded = code
            .get(..index)
            .and_then(|before| before.chars().last())
            .is_some_and(|character| character.is_alphanumeric() || character == '_');
        if preceded {
            continue;
        }
        let tail = code.get(index..).expect("declaration");
        let name: String = tail
            .chars()
            .take_while(|character| character.is_alphanumeric() || *character == '_')
            .collect();
        let after = tail.get(name.len()..).expect("after name").trim_start();
        if after.starts_with('(') {
            let previous = signatures.insert(name.clone(), arity(parenthesised(after)));
            assert!(previous.is_none(), "{name} is declared twice");
        }
    }
    signatures
}

#[test]
fn the_header_declares_exactly_the_exported_functions_with_their_arity() {
    let exported = exported();
    let declared = declared(&header());
    assert!(!exported.is_empty(), "no exported functions were found");
    assert_eq!(
        declared, exported,
        "include/mila_ffi.h differs from the exports"
    );
}

/// `PlanApprove` -> `PLAN_APPROVE`.
fn screaming_snake(variant: &str) -> String {
    let mut out = String::new();
    for (index, character) in variant.char_indices() {
        if character.is_uppercase() && index > 0 {
            out.push('_');
        }
        out.push(character.to_ascii_uppercase());
    }
    out
}

/// `NAME = value` pairs of the brace-delimited body following `marker`.
fn enumerators(text: &str, marker: &str) -> Vec<(String, i64)> {
    let start = text
        .find(marker)
        .unwrap_or_else(|| panic!("{marker} not found"));
    let tail = text.get(start..).expect("enum tail");
    let open = tail.find('{').expect("enum body");
    let close = tail.find('}').expect("enum end");
    let body: String = tail
        .get(open + 1..close)
        .expect("enum body text")
        .lines()
        .filter(|line| {
            let line = line.trim_start();
            !(line.starts_with("//")
                || line.starts_with("#[")
                || line.starts_with("/*")
                || line.starts_with('*'))
        })
        .collect::<Vec<_>>()
        .join(" ");
    body.split(',')
        .filter_map(|item| {
            let (name, value) = item.split_once('=')?;
            Some((
                name.trim().to_owned(),
                value.trim().parse::<i64>().expect("integer discriminant"),
            ))
        })
        .collect()
}

#[test]
fn header_enumerators_match_the_rust_discriminants() {
    let header = header();
    let sources = rust_sources().join("\n");
    for (name, prefix) in ENUMS {
        let rust: Vec<(String, i64)> = enumerators(&sources, &format!("pub enum {name} {{"))
            .into_iter()
            .map(|(variant, value)| (format!("{prefix}{}", screaming_snake(&variant)), value))
            .collect();
        let c = enumerators(&header, &format!("typedef enum {name} {{"));
        assert!(!rust.is_empty(), "{name} has no variants");
        assert_eq!(c, rust, "{name} enumerators differ from the Rust enum");
    }
}

#[test]
fn every_declaration_is_inside_the_include_guard() {
    let header = header();
    let lines: Vec<&str> = header
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    let guard = lines
        .iter()
        .position(|line| *line == "#ifndef MILA_FFI_H")
        .expect("include guard");
    assert!(
        lines
            .get(..guard)
            .expect("prelude")
            .iter()
            .all(|line| line.starts_with("/*") || line.starts_with('*')),
        "only comments may precede the include guard"
    );
    assert_eq!(
        lines.last(),
        Some(&"#endif"),
        "the include guard must close the header"
    );
    let tail = lines.get(lines.len() - 4..).expect("closing lines");
    assert_eq!(tail, ["#ifdef __cplusplus", "}", "#endif", "#endif"]);
}
