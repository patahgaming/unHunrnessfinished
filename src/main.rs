//! Bothea CLI — skeleton.
//!
//! This binary exists so the bundle pipeline has something real to build and verify.
//! It implements the three commands the bundle story needs right now:
//!   - `bothea --version`
//!   - `bothea bundle verify [--dir <dist>]`
//!   - `bothea nullclaw checklist`
//!
//! Everything else in `docs/` is still specification, not code.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Pinned upstream release. Kept here so the checklist can compare what is actually
/// installed; `bothea.toml` and `state/pins.json` remain the authoritative record.
const NULLCLAW_TAG: &str = "v2026.5.29";
const NULLCLAW_COMMIT: &str = "b25c6eb59f845f4f8cdbb50d6f284cb56d723435";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("--version") | Some("-V") | Some("version") | None => {
            println!("bothea {}", env!("CARGO_PKG_VERSION"));
            0
        }
        Some("bundle") => match args.get(1).map(String::as_str) {
            Some("verify") => cmd_bundle_verify(&args[2..]),
            _ => {
                eprintln!("usage: bothea bundle verify [--dir <dist>]");
                1
            }
        },
        Some("nullclaw") => match args.get(1).map(String::as_str) {
            Some("checklist") => cmd_nullclaw_checklist(),
            _ => {
                eprintln!("usage: bothea nullclaw checklist");
                1
            }
        },
        Some("help") | Some("--help") | Some("-h") => {
            println!("bothea {} — bundle skeleton", env!("CARGO_PKG_VERSION"));
            println!("commands: version | bundle verify | nullclaw checklist");
            0
        }
        Some(other) => {
            eprintln!("unknown command: {other}");
            eprintln!("try: bothea help");
            1
        }
    };
    std::process::exit(code);
}

fn path_arg(args: &[String], flag: &str) -> Option<PathBuf> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
}

fn cmd_bundle_verify(args: &[String]) -> i32 {
    let dir = path_arg(args, "--dir").unwrap_or_else(|| PathBuf::from("dist"));
    let manifest = dir.join("manifest.sha256");
    let bundle_json = dir.join("bundle.json");

    println!("bothea bundle verify — {}/", dir.display());

    if !manifest.is_file() {
        eprintln!("  FAIL  manifest.sha256 not found (looked in {})", manifest.display());
        return 2;
    }
    if !bundle_json.is_file() {
        eprintln!("  FAIL  bundle.json not found (looked in {})", bundle_json.display());
        return 2;
    }

    let mut failures = 0usize;
    let mut checked = 0usize;
    let entries = match fs::read_to_string(&manifest) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("  FAIL  cannot read manifest.sha256: {e}");
            return 2;
        }
    };
    for line in entries.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(expected), Some(rel)) = (parts.next(), parts.next()) else {
            eprintln!("  FAIL  malformed manifest line: {line}");
            failures += 1;
            continue;
        };
        let path = dir.join(rel);
        checked += 1;
        if !path.is_file() {
            println!("  MISSING  {rel}");
            failures += 1;
            continue;
        }
        match fs::read(&path) {
            Ok(bytes) => {
                let got = hex(&sha256(&bytes));
                if got == expected.to_ascii_lowercase() {
                    println!("  ok       {rel}");
                } else {
                    println!("  MISMATCH {rel}");
                    println!("           expected {expected}");
                    println!("           got      {got}");
                    failures += 1;
                }
            }
            Err(e) => {
                println!("  ERROR    {rel}: {e}");
                failures += 1;
            }
        }
    }

    let bundle = fs::read_to_string(&bundle_json).unwrap_or_default();
    let tag = scan_json_string(&bundle, "nullclaw_tag");
    let commit = scan_json_string(&bundle, "nullclaw_commit");
    match (&tag, &commit) {
        (Some(t), Some(c)) if t == NULLCLAW_TAG && c == NULLCLAW_COMMIT => {
            println!("  ok       nullclaw pin {t} @ {}", short(c));
        }
        (Some(t), _) => {
            println!("  MISMATCH nullclaw_tag {t} != {NULLCLAW_TAG}");
            failures += 1;
        }
        _ => {
            println!("  MISSING  nullclaw_tag/nullclaw_commit in bundle.json");
            failures += 1;
        }
    }

    // The binary must report the tag, not `dev`; that is the check D-052 promises.
    let exe = dir.join("nullclaw.exe");
    if exe.is_file() {
        match Command::new(&exe).arg("--version").output() {
            Ok(out) => {
                let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if v.contains(NULLCLAW_TAG) {
                    println!("  ok       nullclaw --version = {v}");
                } else {
                    println!("  FAIL     nullclaw --version = {v:?} (does not contain {NULLCLAW_TAG})");
                    failures += 1;
                }
            }
            Err(e) => {
                println!("  FAIL     cannot run bundled nullclaw: {e}");
                failures += 1;
            }
        }
    } else {
        println!("  MISSING  nullclaw.exe");
        failures += 1;
    }

    if failures == 0 {
        println!("bundle verify: OK ({checked} files, pin {NULLCLAW_TAG})");
        0
    } else {
        println!("bundle verify: FAILED ({failures} problem(s) across {checked} files)");
        2
    }
}

fn cmd_nullclaw_checklist() -> i32 {
    println!("bothea nullclaw checklist");
    println!("  pinned release : {NULLCLAW_TAG} @ {}", short(NULLCLAW_COMMIT));

    let candidates = [
        Path::new("dist/nullclaw.exe").to_path_buf(),
        Path::new("vendor/nullclaw/zig-out/bin/nullclaw.exe").to_path_buf(),
    ];
    let Some(bin) = candidates.iter().find(|p| p.is_file()) else {
        println!("  FAIL  no nullclaw.exe found in dist/ or vendor/ (run scripts/build-bundle.ps1)");
        return 2;
    };
    println!("  binary         : {}", bin.display());

    match Command::new(bin).arg("--version").output() {
        Ok(out) => {
            let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if v.contains(NULLCLAW_TAG) {
                println!("  ok    version reports {v}");
            } else {
                println!("  FAIL  version reports {v:?}; expected {NULLCLAW_TAG} (build with -Dversion)");
            }
        }
        Err(e) => println!("  FAIL  cannot execute binary: {e}"),
    }

    println!();
    println!("  Hardening items the lead owns (Bothea prints, it cannot enforce):");
    println!("   [ ] pairing required (6-digit code) and used at least once");
    println!("   [ ] every enabled channel has a non-empty allow_from allowlist");
    println!("   [ ] gateway bound to 127.0.0.1, no public bind, no tunnel unless intended");
    println!("   [ ] a sandbox backend is active (landlock/firejail/bubblewrap/docker)");
    println!("   [ ] audit log on, retention set");
    println!("   [ ] autonomy is supervised with a max_actions_per_hour, not full");
    println!("   [ ] `nullclaw update` is not run: the bundled binary is the pin (D-052)");
    0
}

fn short(s: &str) -> String {
    s.chars().take(12).collect()
}

/// Reads `"key": "value"` out of the bundle metadata. The file is generated by
/// `scripts/build-bundle.ps1`, so a targeted scan is enough; this is not a JSON parser.
fn scan_json_string(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\":");
    let start = text.find(&needle)? + needle.len();
    let rest = &text[start..];
    let q1 = rest.find('"')? + 1;
    let rest = &rest[q1..];
    let q2 = rest.find('"')?;
    Some(rest[..q2].to_string())
}

// ---- SHA-256 (small, dependency-free; used to verify the bundle manifest) ----

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_vectors() {
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hex(&sha256(b"The quick brown fox jumps over the lazy dog")),
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        );
    }
}
