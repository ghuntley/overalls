use crate::ProtocolError;

pub(crate) fn lex(line: &str) -> Result<Vec<String>, ProtocolError> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut mode = 0u8;
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if mode == 1 {
            match character {
                '\'' => mode = 0,
                _ => current.push(character),
            }
            continue;
        }
        if mode == 2 {
            match character {
                '"' => mode = 0,
                '\\' => escaped = true,
                _ => current.push(character),
            }
            continue;
        }
        match character {
            '\\' => escaped = true,
            '\'' => mode = 1,
            '"' => mode = 2,
            character if character.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(character),
        }
    }
    if escaped || mode != 0 {
        return Err(ProtocolError::InvalidCommand);
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    Ok(tokens)
}

pub(crate) fn quote(value: &str) -> String {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._/-".contains(&byte))
    {
        return value.into();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}
