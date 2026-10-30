use super::{FetchEvent, Host};
use reqwest::blocking::Client;
use reqwest::header::{ACCEPT, CONTENT_TYPE};
use reqwest::{redirect::Policy, Url};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;

const DOWNLOAD_LIMIT: usize = 5 * 1024 * 1024;
const RESULT_LIMIT: usize = 10 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Arguments {
    url: String,
    #[serde(default = "default_format")]
    format: String,
    #[serde(default = "default_timeout")]
    timeout: u32,
}

fn default_format() -> String {
    "markdown".to_owned()
}

fn default_timeout() -> u32 {
    30
}

// @cc [owner:ghuntley,label:security;recovery] guest-web-fetch-boundary
// A fetch MUST use only HTTP(S) through the guest network, verify HTTPS, cap
// downloads, redirects, time and serialized results, and report started before
// network effects. URLs, bodies and transport errors MUST NOT enter diagnostics.
pub(super) fn run(host: &impl Host, raw: &Value) -> (&'static str, Value) {
    let Ok(args) = serde_json::from_value::<Arguments>(raw.clone()) else {
        return failed("invalid_arguments");
    };
    if !valid_url(&args.url)
        || !matches!(args.format.as_str(), "markdown" | "text" | "html")
        || !(1..=120).contains(&args.timeout)
    {
        return failed("invalid_arguments");
    }

    host.fetch_event(FetchEvent::Started);
    let outcome = fetch(&args);
    host.fetch_event(if outcome.0 == "completed" {
        FetchEvent::Completed
    } else {
        FetchEvent::Failed
    });
    outcome
}

fn valid_url(url: &str) -> bool {
    if url.len() > 2048 || url.bytes().any(|byte| byte.is_ascii_control()) {
        return false;
    }
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    matches!(parsed.scheme(), "http" | "https")
        && parsed.host().is_some()
        && parsed.username().is_empty()
        && parsed.password().is_none()
}

fn fetch(args: &Arguments) -> (&'static str, Value) {
    let Ok(client) = Client::builder()
        .use_rustls_tls()
        .no_proxy()
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 || !valid_url(attempt.url().as_str()) {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(args.timeout.into()))
        .build()
    else {
        return failed("fetch_unavailable");
    };
    let Ok(response) = client
        .get(&args.url)
        .header(ACCEPT, accept_header(&args.format))
        .send()
    else {
        return failed("fetch_failed");
    };
    if !response.status().is_success() {
        return failed("fetch_failed");
    }
    if response
        .content_length()
        .is_some_and(|length| length > DOWNLOAD_LIMIT as u64)
    {
        return failed("fetch_too_large");
    }
    let mime = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if !matches!(
        mime.as_str(),
        "text/html"
            | "text/plain"
            | "text/markdown"
            | "text/x-markdown"
            | "application/xhtml+xml"
            | "application/json"
            | "application/xml"
            | "text/xml"
            | ""
    ) {
        return failed("unsupported_content_type");
    }
    let mut bytes = Vec::new();
    if response
        .take((DOWNLOAD_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() > DOWNLOAD_LIMIT
    {
        return failed("fetch_too_large");
    }
    let body = String::from_utf8_lossy(&bytes);
    let converted = if matches!(mime.as_str(), "text/html" | "application/xhtml+xml") {
        match args.format.as_str() {
            "html" => body.into_owned(),
            "markdown" => html_content(&body, true),
            _ => html_content(&body, false),
        }
    } else {
        body.into_owned()
    };
    bounded_result(converted, &mime)
}

fn accept_header(format: &str) -> &'static str {
    match format {
        "text" => "text/plain, text/html;q=0.8, */*;q=0.1",
        "html" => "text/html, application/xhtml+xml;q=0.9, */*;q=0.1",
        _ => "text/markdown, text/plain;q=0.9, text/html;q=0.8, */*;q=0.1",
    }
}

fn bounded_result(content: String, content_type: &str) -> (&'static str, Value) {
    let mut kept = content;
    let mut truncated = kept.len() > RESULT_LIMIT;
    if truncated {
        kept.truncate(kept.floor_char_boundary(RESULT_LIMIT));
    }
    loop {
        let result = json!({"content": kept, "content_type": content_type, "truncated": truncated});
        if serde_json::to_vec(&result).is_ok_and(|bytes| bytes.len() <= RESULT_LIMIT) {
            return ("completed", result);
        }
        truncated = true;
        let new_len = kept.len().saturating_sub(512);
        let boundary = kept.floor_char_boundary(new_len);
        kept.truncate(boundary);
    }
}

fn failed(reason: &'static str) -> (&'static str, Value) {
    ("failed", json!({"reason": reason}))
}

fn html_content(source: &str, markdown: bool) -> String {
    let mut out = String::new();
    let mut tag = String::new();
    let mut hidden: Option<String> = None;
    let mut inside_tag = false;
    for ch in source.chars() {
        if ch == '<' && !inside_tag {
            inside_tag = true;
            tag.clear();
        } else if ch == '>' && inside_tag {
            inside_tag = false;
            let name = tag
                .trim_start_matches('/')
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();
            if matches!(
                name.as_str(),
                "script" | "style" | "noscript" | "iframe" | "object"
            ) {
                if tag.starts_with('/') {
                    if hidden.as_deref() == Some(name.as_str()) {
                        hidden = None;
                    }
                } else if hidden.is_none() {
                    hidden = Some(name);
                }
            } else if hidden.is_none() {
                match name.as_str() {
                    "br" | "p" | "div" | "li" | "h1" | "h2" | "h3" | "pre" => {
                        out.push('\n');
                        if markdown && !tag.starts_with('/') {
                            match name.as_str() {
                                "li" => out.push_str("- "),
                                "h1" => out.push_str("# "),
                                "h2" => out.push_str("## "),
                                "h3" => out.push_str("### "),
                                _ => {}
                            }
                        }
                    }
                    _ => {}
                }
            }
        } else if inside_tag {
            if tag.len() < 1024 {
                tag.push(ch);
            }
        } else if hidden.is_none() {
            out.push(ch);
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::{bounded_result, html_content, valid_url, Arguments, RESULT_LIMIT};
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn validates_guest_urls() {
        assert!(valid_url("http://127.0.0.1:8080/health"));
        assert!(valid_url("https://service.internal/path"));
        assert!(!valid_url("file:///etc/passwd"));
        assert!(!valid_url("https://user:pass@service.internal/"));
        assert!(!valid_url("https://host\nmalformed"));
    }

    #[test]
    fn strips_active_html_and_bounds_serialized_output() {
        let converted = html_content(
            "<h1>Title</h1><script>secret()</script><p>Text &amp; more</p>",
            true,
        );
        assert_eq!(converted, "# Title\n\nText & more");
        let (_, result) = bounded_result("\"".repeat(20_000), "text/plain");
        assert!(result["truncated"].as_bool().unwrap());
        assert!(serde_json::to_vec(&result).unwrap().len() <= RESULT_LIMIT);
        let (_, large) = bounded_result("\"".repeat(5 * 1024 * 1024), "text/plain");
        assert!(large["truncated"].as_bool().unwrap());
        assert!(serde_json::to_vec(&large).unwrap().len() <= RESULT_LIMIT);
    }

    #[test]
    fn fetches_from_guest_loopback_without_a_shell() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            let read = stream.read(&mut request).unwrap();
            assert!(request[..read].starts_with(b"GET /local HTTP/1.1"));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 28\r\n\r\n<h1>Guest local content</h1>")
                .unwrap();
        });
        let (state, result) = super::fetch(&Arguments {
            url: format!("http://{address}/local"),
            format: "markdown".to_owned(),
            timeout: 5,
        });
        server.join().unwrap();
        assert_eq!(state, "completed");
        assert_eq!(result["content"], "# Guest local content");
    }
}
