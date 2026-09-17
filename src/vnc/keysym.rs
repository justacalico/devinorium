//! Keysym resolution for VNC key events: named keys, modifier chords like
//! `ctrl+shift+t`, and per-character mapping for typed text.

pub const SHIFT_L: u32 = 0xFFE1;
const CONTROL_L: u32 = 0xFFE3;
const ALT_L: u32 = 0xFFE9;
const SUPER_L: u32 = 0xFFEB;

fn named_key(name: &str) -> Option<u32> {
    let key = match name {
        "backspace" | "bs" => 0xFF08,
        "tab" => 0xFF09,
        "enter" | "return" | "ret" => 0xFF0D,
        "escape" | "esc" => 0xFF1B,
        "home" => 0xFF50,
        "left" => 0xFF51,
        "up" => 0xFF52,
        "right" => 0xFF53,
        "down" => 0xFF54,
        "pageup" | "pgup" | "prior" => 0xFF55,
        "pagedown" | "pgdn" | "next" => 0xFF56,
        "end" => 0xFF57,
        "print" | "printscreen" | "prtsc" => 0xFF61,
        "insert" | "ins" => 0xFF63,
        "numlock" => 0xFF7F,
        "capslock" | "caps" => 0xFFE5,
        "scrolllock" => 0xFF14,
        "pause" | "break" => 0xFF13,
        "delete" | "del" => 0xFFFF,
        "space" | " " => 0x20,
        "shift" => SHIFT_L,
        "ctrl" | "control" => CONTROL_L,
        "alt" => ALT_L,
        "super" | "meta" | "cmd" | "win" => SUPER_L,
        _ => {
            if let Some(rest) = name.strip_prefix('f') {
                if let Ok(n) = rest.parse::<u32>() {
                    if (1..=12).contains(&n) {
                        return Some(0xFFBD + n);
                    }
                }
            }
            return None;
        }
    };
    Some(key)
}

fn modifier_keysym(name: &str) -> Option<u32> {
    match name {
        "shift" => Some(SHIFT_L),
        "ctrl" | "control" => Some(CONTROL_L),
        "alt" => Some(ALT_L),
        "super" | "meta" | "cmd" | "win" => Some(SUPER_L),
        _ => None,
    }
}

/// Parse a chord like `"ctrl+shift+t"` or a single key like `"Return"` or
/// `"a"` into `(modifier keysyms, (key keysym, needs_shift))`.
pub fn key_chord(chord: &str) -> Option<(Vec<u32>, (u32, bool))> {
    let parts: Vec<&str> = chord.split('+').map(|p| p.trim()).collect();
    if parts.is_empty() || parts.iter().any(|p| p.is_empty()) {
        return None;
    }
    let (last, mods) = parts.split_last().unwrap();
    let mut modifiers = Vec::with_capacity(mods.len());
    for m in mods {
        modifiers.push(modifier_keysym(&m.to_ascii_lowercase())?);
    }
    let main = resolve_key(last)?;
    // A char key that needs shift adds it to the held modifiers instead of
    // toggling inside the press, so `shift+a` and `A` behave the same.
    if main.1 && !modifiers.contains(&SHIFT_L) {
        modifiers.push(SHIFT_L);
    }
    Some((modifiers, (main.0, false)))
}

/// One key to press: a named key or a single character.
/// Returns `(keysym, needs_shift)`.
fn resolve_key(key: &str) -> Option<(u32, bool)> {
    let lower = key.to_ascii_lowercase();
    if let Some(sym) = named_key(&lower) {
        return Some((sym, false));
    }
    let mut chars = key.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => text_keysym(c),
        _ => None,
    }
}

/// Map a character to `(keysym, needs_shift)` for `type` input.
/// Printable ASCII maps to itself; shifted symbols resolve to their base
/// key plus shift. Non-ASCII uses the X11 Unicode keysym range.
pub fn text_keysym(c: char) -> Option<(u32, bool)> {
    match c {
        ' '..='~' => {
            // Letters send their lowercase keysym with shift held; shifted
            // symbols send the unshifted key's keysym.
            let base = UNSHIFT_FOR_SHIFTED
                .iter()
                .find(|(shifted, _)| *shifted == c)
                .map(|(_, base)| *base)
                .unwrap_or_else(|| c.to_ascii_lowercase()) as u32;
            let needs_shift = c.is_ascii_uppercase() || SHIFTED_SYMBOLS.contains(&c);
            Some((base, needs_shift))
        }
        '\n' | '\r' => Some((0xFF0D, false)),
        '\t' => Some((0xFF09, false)),
        '\u{00A0}'..='\u{00FF}' => Some((c as u32, false)),
        _ if (c as u32) >= 0x100 => Some((0x01000000 + c as u32, false)),
        _ => None,
    }
}

const SHIFTED_SYMBOLS: &[char] = &[
    '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '{', '}', '|', ':', '"', '<',
    '>', '?',
];

const UNSHIFT_FOR_SHIFTED: &[(char, char)] = &[
    ('~', '`'),
    ('!', '1'),
    ('@', '2'),
    ('#', '3'),
    ('$', '4'),
    ('%', '5'),
    ('^', '6'),
    ('&', '7'),
    ('*', '8'),
    ('(', '9'),
    (')', '0'),
    ('_', '-'),
    ('+', '='),
    ('{', '['),
    ('}', ']'),
    ('|', '\\'),
    (':', ';'),
    ('"', '\''),
    ('<', ','),
    ('>', '.'),
    ('?', '/'),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_keys_resolve() {
        assert_eq!(named_key("return"), Some(0xFF0D));
        assert_eq!(named_key("Enter"), None); // callers lowercase first
        assert_eq!(resolve_key("Enter"), Some((0xFF0D, false)));
        assert_eq!(resolve_key("f5"), Some((0xFFC2, false)));
        assert_eq!(resolve_key("F12"), Some((0xFFC9, false)));
        assert_eq!(resolve_key("f13"), None);
    }

    #[test]
    fn chords_parse_modifiers() {
        let (mods, main) = key_chord("ctrl+c").unwrap();
        assert_eq!(mods, vec![CONTROL_L]);
        assert_eq!(main, ('c' as u32, false));

        let (mods, main) = key_chord("Ctrl + Shift + T").unwrap();
        assert_eq!(mods, vec![CONTROL_L, SHIFT_L]);
        assert_eq!(main, ('t' as u32, false));

        // Shifted char folds shift into the held modifiers.
        let (mods, _) = key_chord("ctrl+A").unwrap();
        assert!(mods.contains(&SHIFT_L) && mods.contains(&CONTROL_L));

        assert!(key_chord("").is_none());
        assert!(key_chord("ctrl+").is_none());
        assert!(key_chord("boguskey").is_none());
        assert!(key_chord("ctrl+alt+del").is_some());
    }

    #[test]
    fn text_keysym_maps_shifted_symbols() {
        assert_eq!(text_keysym('a'), Some(('a' as u32, false)));
        assert_eq!(text_keysym('A'), Some(('a' as u32, true)));
        assert_eq!(text_keysym('!'), Some(('1' as u32, true)));
        assert_eq!(text_keysym('"'), Some(('\'' as u32, true)));
        assert_eq!(text_keysym('\n'), Some((0xFF0D, false)));
        assert_eq!(text_keysym(' '), Some((0x20, false)));
        // Latin-1 and beyond use their own keysym ranges.
        assert_eq!(text_keysym('é'), Some((0xE9, false)));
        assert!(text_keysym('中').unwrap().0 == 0x01000000 + '中' as u32);
    }
}
